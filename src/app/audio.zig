// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Main-thread SDL3_mixer audio service.
//! Game states queue audio intent through AudioCommandBuffer; AudioService owns
//! mixer tracks, loaded audio assets, and SDL_mixer lifetime.

const std = @import("std");
const assets_mod = @import("../assets/assets.zig");
const AssetStore = assets_mod.AssetStore;
const AudioConfig = @import("../config.zig").AudioConfig;
const log = @import("../core/logging.zig").audio;
const math = @import("../core/math.zig");
const sdl = @import("../platform/sdl.zig");
const c = sdl.c;

const BackendHandle = usize;
const invalid_backend_handle: BackendHandle = 0;

pub const AudioBus = enum {
    sfx,
    music,
};

pub const PlaySfxRequest = struct {
    path: []const u8,
    gain: f32 = 1.0,
    priority: u8 = 128,
    position: ?math.Vec2 = null,
};

pub const MusicRequest = struct {
    path: []const u8,
    gain: f32 = 1.0,
    loop: bool = true,
    fade_in_ms: u32 = 750,
    restart: bool = false,
};

const OwnedPlaySfxRequest = struct {
    path: []const u8,
    gain: f32,
    priority: u8,
    position: ?math.Vec2,
};

const OwnedMusicRequest = struct {
    path: []const u8,
    gain: f32,
    loop: bool,
    fade_in_ms: u32,
    restart: bool,
};

pub const AudioCommand = union(enum) {
    play_sfx: OwnedPlaySfxRequest,
    play_music: OwnedMusicRequest,
    stop_music: u32,
    set_listener: math.Vec2,
    set_bus_gain: BusGain,
    set_master_gain: f32,

    fn path(self: AudioCommand) ?[]const u8 {
        return switch (self) {
            .play_sfx => |request| request.path,
            .play_music => |request| request.path,
            else => null,
        };
    }
};

pub const BusGain = struct {
    bus: AudioBus,
    gain: f32,
};

pub const AudioCommandBuffer = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(AudioCommand) = .empty,
    max_commands: usize,

    pub fn init(allocator: std.mem.Allocator, max_commands: usize) AudioCommandBuffer {
        return .{
            .allocator = allocator,
            .max_commands = @max(max_commands, 1),
        };
    }

    pub fn deinit(self: *AudioCommandBuffer) void {
        self.clearRetainingCapacity();
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn beginStep(self: *AudioCommandBuffer) void {
        self.clearRetainingCapacity();
    }

    pub fn len(self: *const AudioCommandBuffer) usize {
        return self.commands.items.len;
    }

    pub fn items(self: *const AudioCommandBuffer) []const AudioCommand {
        return self.commands.items;
    }

    pub fn playSfx(self: *AudioCommandBuffer, request: PlaySfxRequest) !void {
        try assets_mod.validateRelativePath(request.path);
        const path = try self.copyPathForCommand(request.path);
        errdefer self.allocator.free(path);
        try self.append(.{ .play_sfx = .{
            .path = path,
            .gain = clampGain(request.gain),
            .priority = request.priority,
            .position = request.position,
        } });
    }

    pub fn playMusic(self: *AudioCommandBuffer, request: MusicRequest) !void {
        try assets_mod.validateRelativePath(request.path);
        const path = try self.copyPathForCommand(request.path);
        errdefer self.allocator.free(path);
        try self.append(.{ .play_music = .{
            .path = path,
            .gain = clampGain(request.gain),
            .loop = request.loop,
            .fade_in_ms = request.fade_in_ms,
            .restart = request.restart,
        } });
    }

    pub fn stopMusic(self: *AudioCommandBuffer, fade_out_ms: u32) !void {
        try self.append(.{ .stop_music = fade_out_ms });
    }

    pub fn setListener(self: *AudioCommandBuffer, listener: math.Vec2) !void {
        try self.append(.{ .set_listener = listener });
    }

    pub fn setBusGain(self: *AudioCommandBuffer, bus: AudioBus, gain: f32) !void {
        try self.append(.{ .set_bus_gain = .{ .bus = bus, .gain = clampGain(gain) } });
    }

    pub fn setMasterGain(self: *AudioCommandBuffer, gain: f32) !void {
        try self.append(.{ .set_master_gain = clampGain(gain) });
    }

    fn append(self: *AudioCommandBuffer, command: AudioCommand) !void {
        if (self.commands.items.len >= self.max_commands) {
            return error.AudioCommandLimitReached;
        }
        try self.commands.append(self.allocator, command);
    }

    fn copyPathForCommand(self: *AudioCommandBuffer, path: []const u8) ![]const u8 {
        return try self.allocator.dupe(u8, path);
    }

    fn clearRetainingCapacity(self: *AudioCommandBuffer) void {
        for (self.commands.items) |command| {
            if (command.path()) |path| self.allocator.free(path);
        }
        self.commands.clearRetainingCapacity();
    }
};

pub const AudioService = struct {
    allocator: std.mem.Allocator,
    assets: AssetStore,
    config: AudioConfig,
    enabled: bool,
    backend: Backend,
    backend_context: *anyopaque,
    owns_backend_context: bool = false,
    entries: std.StringHashMapUnmanaged(AudioEntry) = .empty,
    failed_paths: std.StringHashMapUnmanaged(void) = .empty,
    sfx_tracks: std.ArrayList(TrackSlot) = .empty,
    music_track: BackendHandle = invalid_backend_handle,
    current_music_path: ?[]const u8 = null,
    master_gain: f32,
    sfx_gain: f32,
    music_gain: f32,
    active_music_gain: f32 = 1.0,
    listener: math.Vec2 = .{},
    paused: bool = false,
    sequence: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, assets: AssetStore, config: AudioConfig) !AudioService {
        var service = AudioService{
            .allocator = allocator,
            .assets = assets,
            .config = config,
            .enabled = config.enabled,
            .backend = disabledBackend(),
            .backend_context = undefined,
            .master_gain = config.master_gain,
            .sfx_gain = config.sfx_gain,
            .music_gain = config.music_gain,
        };
        service.backend_context = @ptrCast(&service);
        if (!config.enabled) return service;

        const production_context = try allocator.create(ProductionBackendContext);
        var context_initialized = false;
        errdefer if (!context_initialized) allocator.destroy(production_context);
        production_context.* = try ProductionBackendContext.init(config.master_gain);
        context_initialized = true;
        errdefer production_context.deinit();

        service.backend = productionBackend();
        service.backend_context = @ptrCast(production_context);
        service.owns_backend_context = true;
        try service.createTracks();
        log.debug("audio initialized: sfx_tracks={} master_gain={} sfx_gain={} music_gain={}", .{
            service.sfx_tracks.items.len,
            service.master_gain,
            service.sfx_gain,
            service.music_gain,
        });
        return service;
    }

    pub fn initWithBackend(
        allocator: std.mem.Allocator,
        assets: AssetStore,
        config: AudioConfig,
        backend: Backend,
        backend_context: *anyopaque,
    ) !AudioService {
        var service = AudioService{
            .allocator = allocator,
            .assets = assets,
            .config = config,
            .enabled = config.enabled,
            .backend = backend,
            .backend_context = backend_context,
            .master_gain = config.master_gain,
            .sfx_gain = config.sfx_gain,
            .music_gain = config.music_gain,
        };
        if (config.enabled) try service.createTracks();
        return service;
    }

    pub fn deinit(self: *AudioService) void {
        for (self.sfx_tracks.items) |track| {
            self.backend.destroy_track(self.backend_context, track.handle);
        }
        self.sfx_tracks.deinit(self.allocator);
        if (self.music_track != invalid_backend_handle) {
            self.backend.destroy_track(self.backend_context, self.music_track);
        }

        var entries = self.entries.iterator();
        while (entries.next()) |entry| {
            self.backend.destroy_audio(self.backend_context, entry.value_ptr.handle);
            self.allocator.free(entry.value_ptr.path);
        }
        self.entries.deinit(self.allocator);

        var failed = self.failed_paths.iterator();
        while (failed.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.failed_paths.deinit(self.allocator);

        if (self.owns_backend_context) {
            const context: *ProductionBackendContext = @ptrCast(@alignCast(self.backend_context));
            context.deinit();
            self.allocator.destroy(context);
        }
        self.* = undefined;
    }

    pub fn drain(self: *AudioService, commands: *const AudioCommandBuffer) void {
        if (!self.enabled) return;
        for (commands.items()) |command| {
            self.applyCommand(command) catch |err| {
                log.warn("audio command ignored: {}", .{err});
            };
        }
    }

    pub fn setPaused(self: *AudioService, paused: bool) void {
        if (!self.enabled or self.paused == paused) return;
        self.paused = paused;
        if (paused) {
            self.stopAllSfx();
        }
        self.applyMusicGain();
    }

    fn createTracks(self: *AudioService) !void {
        self.music_track = try self.backend.create_track(self.backend_context);
        errdefer {
            self.backend.destroy_track(self.backend_context, self.music_track);
            self.music_track = invalid_backend_handle;
        }
        try self.sfx_tracks.ensureTotalCapacity(self.allocator, self.config.max_sfx_tracks);
        for (0..self.config.max_sfx_tracks) |_| {
            const handle = try self.backend.create_track(self.backend_context);
            errdefer self.backend.destroy_track(self.backend_context, handle);
            self.sfx_tracks.appendAssumeCapacity(.{ .handle = handle });
        }
    }

    fn applyCommand(self: *AudioService, command: AudioCommand) !void {
        switch (command) {
            .play_sfx => |request| try self.playSfx(request),
            .play_music => |request| try self.playMusic(request),
            .stop_music => |fade_out_ms| try self.stopMusic(fade_out_ms),
            .set_listener => |listener| self.listener = listener,
            .set_bus_gain => |bus_gain| {
                switch (bus_gain.bus) {
                    .sfx => self.sfx_gain = clampGain(bus_gain.gain),
                    .music => self.music_gain = clampGain(bus_gain.gain),
                }
                self.applyBusGains();
            },
            .set_master_gain => |gain| {
                self.master_gain = clampGain(gain);
                try self.backend.set_mixer_gain(self.backend_context, self.master_gain);
            },
        }
    }

    fn playSfx(self: *AudioService, request: OwnedPlaySfxRequest) !void {
        const audio = try self.loadAudio(request.path, true) orelse return;
        const slot_index = try self.selectSfxTrack(request.priority) orelse return;
        const slot = &self.sfx_tracks.items[slot_index];
        try self.backend.stop_track(self.backend_context, slot.handle, 0);
        try self.backend.set_track_audio(self.backend_context, slot.handle, audio);
        slot.request_gain = request.gain;
        try self.backend.set_track_gain(self.backend_context, slot.handle, request.gain * self.sfx_gain);
        try self.applyTrackPosition(slot.handle, request.position);
        try self.backend.play_track(self.backend_context, slot.handle, 0, 0);
        slot.priority = request.priority;
        slot.sequence = self.sequence;
        self.sequence +%= 1;
    }

    fn playMusic(self: *AudioService, request: OwnedMusicRequest) !void {
        const audio = try self.loadAudio(request.path, false) orelse return;
        if (!request.restart) {
            if (self.current_music_path) |current| {
                if (std.mem.eql(u8, current, request.path)) {
                    self.active_music_gain = request.gain;
                    self.applyMusicGain();
                    return;
                }
            }
        }

        try self.backend.stop_track(self.backend_context, self.music_track, 0);
        try self.backend.set_track_audio(self.backend_context, self.music_track, audio);
        self.active_music_gain = request.gain;
        self.current_music_path = request.path;
        try self.backend.set_track_gain(self.backend_context, self.music_track, self.effectiveMusicGain());
        try self.backend.play_track(self.backend_context, self.music_track, if (request.loop) -1 else 0, request.fade_in_ms);
    }

    fn stopMusic(self: *AudioService, fade_out_ms: u32) !void {
        try self.backend.stop_track(self.backend_context, self.music_track, fade_out_ms);
        self.current_music_path = null;
    }

    fn stopAllSfx(self: *AudioService) void {
        for (self.sfx_tracks.items) |*slot| {
            self.backend.stop_track(self.backend_context, slot.handle, 0) catch {};
            slot.priority = 0;
            slot.request_gain = 1.0;
        }
    }

    fn applyBusGains(self: *AudioService) void {
        for (self.sfx_tracks.items) |slot| {
            self.backend.set_track_gain(self.backend_context, slot.handle, slot.request_gain * self.sfx_gain) catch {};
        }
        self.applyMusicGain();
    }

    fn applyMusicGain(self: *AudioService) void {
        self.backend.set_track_gain(self.backend_context, self.music_track, self.effectiveMusicGain()) catch {};
    }

    fn effectiveMusicGain(self: *const AudioService) f32 {
        const pause_gain = if (self.paused) self.config.paused_music_gain else 1.0;
        return self.active_music_gain * self.music_gain * pause_gain;
    }

    fn selectSfxTrack(self: *AudioService, priority: u8) !?usize {
        var steal_index: ?usize = null;
        for (self.sfx_tracks.items, 0..) |*slot, index| {
            if (!try self.backend.track_playing(self.backend_context, slot.handle)) {
                slot.priority = 0;
                return index;
            }
            if (steal_index == null or lowerPriority(slot.*, self.sfx_tracks.items[steal_index.?])) {
                steal_index = index;
            }
        }
        const index = steal_index orelse return null;
        if (priority < self.sfx_tracks.items[index].priority) return null;
        return index;
    }

    fn lowerPriority(a: TrackSlot, b: TrackSlot) bool {
        if (a.priority != b.priority) return a.priority < b.priority;
        return a.sequence < b.sequence;
    }

    fn applyTrackPosition(self: *AudioService, track: BackendHandle, position: ?math.Vec2) !void {
        const position_3d = if (position) |world_position| BackendPosition{
            .x = (world_position.x - self.listener.x) / self.config.spatial_units_per_meter,
            .y = -(world_position.y - self.listener.y) / self.config.spatial_units_per_meter,
            .z = 0,
        } else null;
        try self.backend.set_track_position(self.backend_context, track, position_3d);
    }

    fn loadAudio(self: *AudioService, relative_path: []const u8, predecode: bool) !?BackendHandle {
        try assets_mod.validateRelativePath(relative_path);
        if (self.entries.get(relative_path)) |entry| {
            return entry.handle;
        }
        if (self.failed_paths.get(relative_path) != null) {
            return null;
        }

        const owned_path = try self.allocator.dupe(u8, relative_path);
        var owns_path = true;
        errdefer if (owns_path) self.allocator.free(owned_path);

        const load_path = if (self.backend.resolve_asset_path)
            self.assets.resolveReadablePath(relative_path) catch |err| {
                try self.rememberFailedPath(owned_path, &owns_path);
                if (self.backend.log_load_failures) {
                    log.warn("audio asset unavailable \"{s}\": {}", .{ relative_path, err });
                }
                return null;
            }
        else
            try self.allocator.dupe(u8, relative_path);
        defer self.allocator.free(load_path);

        const load_path_z = try self.allocator.dupeZ(u8, load_path);
        defer self.allocator.free(load_path_z);
        const handle = self.backend.load_audio(self.backend_context, load_path_z, predecode) catch |err| {
            try self.rememberFailedPath(owned_path, &owns_path);
            if (self.backend.log_load_failures) {
                log.warn("audio load failed \"{s}\": {}", .{ relative_path, err });
            }
            return null;
        };

        try self.entries.put(self.allocator, owned_path, .{
            .path = owned_path,
            .handle = handle,
        });
        owns_path = false;
        log.debug("loaded audio asset \"{s}\" predecode={}", .{ relative_path, predecode });
        return handle;
    }

    fn rememberFailedPath(self: *AudioService, owned_path: []const u8, owns_path: *bool) !void {
        try self.failed_paths.put(self.allocator, owned_path, {});
        owns_path.* = false;
    }
};

const AudioEntry = struct {
    path: []const u8,
    handle: BackendHandle,
};

const TrackSlot = struct {
    handle: BackendHandle,
    priority: u8 = 0,
    sequence: u64 = 0,
    request_gain: f32 = 1.0,
};

const BackendPosition = struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const Backend = struct {
    context_name: []const u8,
    resolve_asset_path: bool = true,
    log_load_failures: bool = true,
    create_track: *const fn (*anyopaque) anyerror!BackendHandle,
    destroy_track: *const fn (*anyopaque, BackendHandle) void,
    load_audio: *const fn (*anyopaque, [:0]const u8, bool) anyerror!BackendHandle,
    destroy_audio: *const fn (*anyopaque, BackendHandle) void,
    set_track_audio: *const fn (*anyopaque, BackendHandle, BackendHandle) anyerror!void,
    play_track: *const fn (*anyopaque, BackendHandle, i32, u32) anyerror!void,
    stop_track: *const fn (*anyopaque, BackendHandle, u32) anyerror!void,
    track_playing: *const fn (*anyopaque, BackendHandle) anyerror!bool,
    set_track_gain: *const fn (*anyopaque, BackendHandle, f32) anyerror!void,
    set_mixer_gain: *const fn (*anyopaque, f32) anyerror!void,
    set_track_position: *const fn (*anyopaque, BackendHandle, ?BackendPosition) anyerror!void,
};

const ProductionBackendContext = struct {
    mixer: *c.MIX_Mixer,

    fn init(master_gain: f32) !ProductionBackendContext {
        if (!c.MIX_Init()) return audioError("MIX_Init");
        errdefer c.MIX_Quit();
        const mixer = c.MIX_CreateMixerDevice(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, null) orelse {
            return audioError("MIX_CreateMixerDevice");
        };
        errdefer c.MIX_DestroyMixer(mixer);
        if (!c.MIX_SetMixerGain(mixer, master_gain)) return audioError("MIX_SetMixerGain");
        return .{ .mixer = mixer };
    }

    fn deinit(self: *ProductionBackendContext) void {
        c.MIX_DestroyMixer(self.mixer);
        c.MIX_Quit();
    }
};

fn productionBackend() Backend {
    return .{
        .context_name = "SDL3_mixer",
        .create_track = productionCreateTrack,
        .destroy_track = productionDestroyTrack,
        .load_audio = productionLoadAudio,
        .destroy_audio = productionDestroyAudio,
        .set_track_audio = productionSetTrackAudio,
        .play_track = productionPlayTrack,
        .stop_track = productionStopTrack,
        .track_playing = productionTrackPlaying,
        .set_track_gain = productionSetTrackGain,
        .set_mixer_gain = productionSetMixerGain,
        .set_track_position = productionSetTrackPosition,
    };
}

fn productionCreateTrack(context: *anyopaque) !BackendHandle {
    const production: *ProductionBackendContext = @ptrCast(@alignCast(context));
    const track = c.MIX_CreateTrack(production.mixer) orelse return audioError("MIX_CreateTrack");
    return @intFromPtr(track);
}

fn productionDestroyTrack(_: *anyopaque, handle: BackendHandle) void {
    c.MIX_DestroyTrack(trackFromHandle(handle));
}

fn productionLoadAudio(context: *anyopaque, path: [:0]const u8, predecode: bool) !BackendHandle {
    const production: *ProductionBackendContext = @ptrCast(@alignCast(context));
    const audio = c.MIX_LoadAudio(production.mixer, path.ptr, predecode) orelse return audioError("MIX_LoadAudio");
    return @intFromPtr(audio);
}

fn productionDestroyAudio(_: *anyopaque, handle: BackendHandle) void {
    c.MIX_DestroyAudio(audioFromHandle(handle));
}

fn productionSetTrackAudio(_: *anyopaque, track: BackendHandle, audio: BackendHandle) !void {
    if (!c.MIX_SetTrackAudio(trackFromHandle(track), audioFromHandle(audio))) return audioError("MIX_SetTrackAudio");
}

fn productionPlayTrack(_: *anyopaque, track: BackendHandle, loops: i32, fade_in_ms: u32) !void {
    const props = c.SDL_CreateProperties();
    if (props == 0) return audioError("SDL_CreateProperties");
    defer c.SDL_DestroyProperties(props);
    if (!c.SDL_SetNumberProperty(props, c.MIX_PROP_PLAY_LOOPS_NUMBER, loops)) return audioError("SDL_SetNumberProperty");
    if (fade_in_ms > 0) {
        if (!c.SDL_SetNumberProperty(props, c.MIX_PROP_PLAY_FADE_IN_MILLISECONDS_NUMBER, fade_in_ms)) return audioError("SDL_SetNumberProperty");
    }
    if (!c.MIX_PlayTrack(trackFromHandle(track), props)) return audioError("MIX_PlayTrack");
}

fn productionStopTrack(_: *anyopaque, track: BackendHandle, fade_out_ms: u32) !void {
    const frames = if (fade_out_ms == 0) 0 else c.MIX_TrackMSToFrames(trackFromHandle(track), fade_out_ms);
    if (!c.MIX_StopTrack(trackFromHandle(track), frames)) return audioError("MIX_StopTrack");
}

fn productionTrackPlaying(_: *anyopaque, track: BackendHandle) !bool {
    return c.MIX_TrackPlaying(trackFromHandle(track));
}

fn productionSetTrackGain(_: *anyopaque, track: BackendHandle, gain: f32) !void {
    if (!c.MIX_SetTrackGain(trackFromHandle(track), gain)) return audioError("MIX_SetTrackGain");
}

fn productionSetMixerGain(context: *anyopaque, gain: f32) !void {
    const production: *ProductionBackendContext = @ptrCast(@alignCast(context));
    if (!c.MIX_SetMixerGain(production.mixer, gain)) return audioError("MIX_SetMixerGain");
}

fn productionSetTrackPosition(_: *anyopaque, track: BackendHandle, position: ?BackendPosition) !void {
    if (position) |value| {
        const point = c.MIX_Point3D{ .x = value.x, .y = value.y, .z = value.z };
        if (!c.MIX_SetTrack3DPosition(trackFromHandle(track), &point)) return audioError("MIX_SetTrack3DPosition");
    } else {
        if (!c.MIX_SetTrack3DPosition(trackFromHandle(track), null)) return audioError("MIX_SetTrack3DPosition");
    }
}

fn audioFromHandle(handle: BackendHandle) *c.MIX_Audio {
    return @ptrFromInt(handle);
}

fn trackFromHandle(handle: BackendHandle) *c.MIX_Track {
    return @ptrFromInt(handle);
}

fn audioError(comptime operation: []const u8) error{AudioBackendFailure} {
    log.err("{s} failed: {s}", .{ operation, c.SDL_GetError() });
    return error.AudioBackendFailure;
}

fn disabledBackend() Backend {
    return .{
        .context_name = "disabled",
        .resolve_asset_path = false,
        .create_track = disabledCreateTrack,
        .destroy_track = disabledDestroyTrack,
        .load_audio = disabledLoadAudio,
        .destroy_audio = disabledDestroyAudio,
        .set_track_audio = disabledSetTrackAudio,
        .play_track = disabledPlayTrack,
        .stop_track = disabledStopTrack,
        .track_playing = disabledTrackPlaying,
        .set_track_gain = disabledSetTrackGain,
        .set_mixer_gain = disabledSetMixerGain,
        .set_track_position = disabledSetTrackPosition,
    };
}

fn disabledCreateTrack(_: *anyopaque) !BackendHandle {
    return invalid_backend_handle;
}

fn disabledDestroyTrack(_: *anyopaque, _: BackendHandle) void {}

fn disabledLoadAudio(_: *anyopaque, _: [:0]const u8, _: bool) !BackendHandle {
    return invalid_backend_handle;
}

fn disabledDestroyAudio(_: *anyopaque, _: BackendHandle) void {}

fn disabledSetTrackAudio(_: *anyopaque, _: BackendHandle, _: BackendHandle) !void {}

fn disabledPlayTrack(_: *anyopaque, _: BackendHandle, _: i32, _: u32) !void {}

fn disabledStopTrack(_: *anyopaque, _: BackendHandle, _: u32) !void {}

fn disabledTrackPlaying(_: *anyopaque, _: BackendHandle) !bool {
    return false;
}

fn disabledSetTrackGain(_: *anyopaque, _: BackendHandle, _: f32) !void {}

fn disabledSetMixerGain(_: *anyopaque, _: f32) !void {}

fn disabledSetTrackPosition(_: *anyopaque, _: BackendHandle, _: ?BackendPosition) !void {}

fn clampGain(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    return std.math.clamp(value, 0, 1);
}

const FakeBackendContext = struct {
    allocator: std.mem.Allocator,
    next_handle: BackendHandle = 1,
    tracks: std.AutoHashMapUnmanaged(BackendHandle, FakeTrack) = .empty,
    audios: std.AutoHashMapUnmanaged(BackendHandle, FakeAudio) = .empty,
    mixer_gain: f32 = 1.0,
    load_failures: std.StringHashMapUnmanaged(void) = .empty,
    load_calls: u32 = 0,
    play_calls: u32 = 0,

    fn init(allocator: std.mem.Allocator) FakeBackendContext {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FakeBackendContext) void {
        var audios = self.audios.iterator();
        while (audios.next()) |entry| {
            self.allocator.free(entry.value_ptr.path);
        }
        self.audios.deinit(self.allocator);
        self.tracks.deinit(self.allocator);
        var failures = self.load_failures.iterator();
        while (failures.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.load_failures.deinit(self.allocator);
    }

    fn backend() Backend {
        return .{
            .context_name = "fake",
            .resolve_asset_path = false,
            .log_load_failures = false,
            .create_track = fakeCreateTrack,
            .destroy_track = fakeDestroyTrack,
            .load_audio = fakeLoadAudio,
            .destroy_audio = fakeDestroyAudio,
            .set_track_audio = fakeSetTrackAudio,
            .play_track = fakePlayTrack,
            .stop_track = fakeStopTrack,
            .track_playing = fakeTrackPlaying,
            .set_track_gain = fakeSetTrackGain,
            .set_mixer_gain = fakeSetMixerGain,
            .set_track_position = fakeSetTrackPosition,
        };
    }

    fn failPath(self: *FakeBackendContext, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        try self.load_failures.put(self.allocator, owned_path, {});
    }

    fn next(self: *FakeBackendContext) BackendHandle {
        const handle = self.next_handle;
        self.next_handle += 1;
        return handle;
    }
};

const FakeTrack = struct {
    audio: BackendHandle = invalid_backend_handle,
    playing: bool = false,
    gain: f32 = 1.0,
    loops: i32 = 0,
    fade_ms: u32 = 0,
    position: ?BackendPosition = null,
};

const FakeAudio = struct {
    path: []const u8,
    predecode: bool,
};

fn fakeCreateTrack(context: *anyopaque) !BackendHandle {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const handle = fake.next();
    try fake.tracks.put(fake.allocator, handle, .{});
    return handle;
}

fn fakeDestroyTrack(context: *anyopaque, handle: BackendHandle) void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    _ = fake.tracks.remove(handle);
}

fn fakeLoadAudio(context: *anyopaque, path: [:0]const u8, predecode: bool) !BackendHandle {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    fake.load_calls += 1;
    if (fake.load_failures.get(path) != null) return error.AudioBackendFailure;
    const handle = fake.next();
    try fake.audios.put(fake.allocator, handle, .{
        .path = try fake.allocator.dupe(u8, path),
        .predecode = predecode,
    });
    return handle;
}

fn fakeDestroyAudio(context: *anyopaque, handle: BackendHandle) void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const removed = fake.audios.fetchRemove(handle) orelse return;
    fake.allocator.free(removed.value.path);
}

fn fakeSetTrackAudio(context: *anyopaque, track: BackendHandle, audio: BackendHandle) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    slot.audio = audio;
}

fn fakePlayTrack(context: *anyopaque, track: BackendHandle, loops: i32, fade_ms: u32) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    slot.playing = true;
    slot.loops = loops;
    slot.fade_ms = fade_ms;
    fake.play_calls += 1;
}

fn fakeStopTrack(context: *anyopaque, track: BackendHandle, _: u32) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    slot.playing = false;
}

fn fakeTrackPlaying(context: *anyopaque, track: BackendHandle) !bool {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    return slot.playing;
}

fn fakeSetTrackGain(context: *anyopaque, track: BackendHandle, gain: f32) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    slot.gain = gain;
}

fn fakeSetMixerGain(context: *anyopaque, gain: f32) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    fake.mixer_gain = gain;
}

fn fakeSetTrackPosition(context: *anyopaque, track: BackendHandle, position: ?BackendPosition) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    slot.position = position;
}

test "audio command buffer validates paths and owns copied command paths" {
    var commands = AudioCommandBuffer.init(std.testing.allocator, 4);
    defer commands.deinit();

    const mutable_path = try std.testing.allocator.dupe(u8, "audio/sfx/hit.wav");
    defer std.testing.allocator.free(mutable_path);
    try commands.playSfx(.{ .path = mutable_path, .gain = 2.0 });
    mutable_path[0] = 'X';

    try std.testing.expectEqual(@as(usize, 1), commands.len());
    try std.testing.expectEqualStrings("audio/sfx/hit.wav", commands.items()[0].play_sfx.path);
    try std.testing.expectEqual(@as(f32, 1.0), commands.items()[0].play_sfx.gain);
    try std.testing.expectError(error.InvalidAssetPath, commands.playSfx(.{ .path = "../bad.wav" }));
}

test "audio command buffer enforces per-step command cap" {
    var commands = AudioCommandBuffer.init(std.testing.allocator, 1);
    defer commands.deinit();

    try commands.playSfx(.{ .path = "audio/sfx/one.wav" });
    try std.testing.expectError(error.AudioCommandLimitReached, commands.playSfx(.{ .path = "audio/sfx/two.wav" }));
    try std.testing.expectEqual(@as(usize, 1), commands.len());
    commands.beginStep();
    try std.testing.expectEqual(@as(usize, 0), commands.len());
}

test "audio service caches loads and memoizes failed paths" {
    var fake = FakeBackendContext.init(std.testing.allocator);
    defer fake.deinit();
    try fake.failPath("audio/sfx/missing.wav");
    const assets = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var service = try AudioService.initWithBackend(std.testing.allocator, assets, .{ .max_sfx_tracks = 2 }, FakeBackendContext.backend(), @ptrCast(&fake));
    defer service.deinit();
    var commands = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer commands.deinit();

    try commands.playSfx(.{ .path = "audio/sfx/hit.wav" });
    try commands.playSfx(.{ .path = "audio/sfx/hit.wav" });
    try commands.playSfx(.{ .path = "audio/sfx/missing.wav" });
    try commands.playSfx(.{ .path = "audio/sfx/missing.wav" });
    service.drain(&commands);

    try std.testing.expectEqual(@as(u32, 2), fake.load_calls);
    try std.testing.expectEqual(@as(usize, 1), service.entries.count());
    try std.testing.expectEqual(@as(usize, 1), service.failed_paths.count());
}

test "audio service plays music idempotently and ducks on pause" {
    var fake = FakeBackendContext.init(std.testing.allocator);
    defer fake.deinit();
    const assets = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var service = try AudioService.initWithBackend(std.testing.allocator, assets, .{
        .max_sfx_tracks = 1,
        .music_gain = 0.5,
        .paused_music_gain = 0.25,
    }, FakeBackendContext.backend(), @ptrCast(&fake));
    defer service.deinit();
    var commands = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer commands.deinit();

    try commands.playMusic(.{ .path = "audio/music/theme.wav", .gain = 0.8, .fade_in_ms = 100 });
    try commands.playMusic(.{ .path = "audio/music/theme.wav", .gain = 0.8, .fade_in_ms = 100 });
    service.drain(&commands);
    try std.testing.expectEqual(@as(u32, 1), fake.play_calls);

    const music = fake.tracks.get(service.music_track).?;
    try std.testing.expectEqual(@as(i32, -1), music.loops);
    try std.testing.expectEqual(@as(u32, 100), music.fade_ms);
    try std.testing.expectEqual(@as(f32, 0.4), music.gain);
    service.setPaused(true);
    try std.testing.expectEqual(@as(f32, 0.1), fake.tracks.get(service.music_track).?.gain);
    service.setPaused(false);
    try std.testing.expectEqual(@as(f32, 0.4), fake.tracks.get(service.music_track).?.gain);
}

test "audio service applies spatial position relative to listener" {
    var fake = FakeBackendContext.init(std.testing.allocator);
    defer fake.deinit();
    const assets = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var service = try AudioService.initWithBackend(std.testing.allocator, assets, .{
        .max_sfx_tracks = 1,
        .spatial_units_per_meter = 100,
    }, FakeBackendContext.backend(), @ptrCast(&fake));
    defer service.deinit();
    var commands = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer commands.deinit();

    try commands.setListener(.{ .x = 50, .y = 50 });
    try commands.playSfx(.{ .path = "audio/sfx/hit.wav", .position = .{ .x = 250, .y = 150 } });
    service.drain(&commands);

    const track = fake.tracks.get(service.sfx_tracks.items[0].handle).?;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), track.position.?.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), track.position.?.y, 0.001);
}
