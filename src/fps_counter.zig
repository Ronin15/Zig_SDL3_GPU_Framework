// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const Renderer = @import("renderer.zig").Renderer;
const TextureHandle = @import("renderer.zig").TextureHandle;
const sdl = @import("sdl.zig");
const c = sdl.c;

const yellow = c.SDL_Color{ .r = 255, .g = 230, .b = 40, .a = 255 };
const sample_window_ns = std.time.ns_per_s / 4;
const font_size: f32 = 18;
const overlay_layer: i32 = 10_000;

pub const FpsCounter = struct {
    font: *c.TTF_Font,
    texture: ?TextureHandle = null,
    texture_width: u32 = 0,
    texture_height: u32 = 0,
    visible: bool = false,
    accumulated_ns: u64 = 0,
    sampled_frames: u32 = 0,
    displayed_fps: u32 = 0,

    pub fn init() !FpsCounter {
        if (!c.TTF_Init()) {
            return sdlError("TTF_Init");
        }
        errdefer c.TTF_Quit();

        const font = try openSystemFont();
        return .{ .font = font };
    }

    pub fn deinit(self: *FpsCounter, renderer: *Renderer) void {
        renderer.waitForIdle();
        self.destroyTexture(renderer);
        c.TTF_CloseFont(self.font);
        c.TTF_Quit();
    }

    pub fn toggle(self: *FpsCounter) void {
        self.visible = !self.visible;
    }

    pub fn update(self: *FpsCounter, renderer: *Renderer, frame_delta_ns: u64) !void {
        self.sampled_frames += 1;
        self.accumulated_ns += frame_delta_ns;

        if (self.texture == null or self.accumulated_ns >= sample_window_ns) {
            if (self.accumulated_ns > 0) {
                self.displayed_fps = @intFromFloat(@round(
                    (@as(f64, @floatFromInt(self.sampled_frames)) * @as(f64, @floatFromInt(std.time.ns_per_s))) /
                        @as(f64, @floatFromInt(self.accumulated_ns)),
                ));
            }
            self.sampled_frames = 0;
            self.accumulated_ns = 0;
            try self.rebuildTexture(renderer);
        }
    }

    pub fn render(self: *const FpsCounter, renderer: *Renderer) !void {
        if (!self.visible) return;

        const texture = self.texture orelse return;
        try renderer.drawSprite(.{
            .texture = texture,
            .dest = .{
                .x = 12,
                .y = 10,
                .w = @floatFromInt(self.texture_width),
                .h = @floatFromInt(self.texture_height),
            },
            .layer = overlay_layer,
            .screen_space = true,
        });
    }

    fn rebuildTexture(self: *FpsCounter, renderer: *Renderer) !void {
        var text_buffer: [32]u8 = undefined;
        const text = try std.fmt.bufPrintZ(&text_buffer, "FPS {d}", .{self.displayed_fps});

        const surface = c.TTF_RenderText_Blended(self.font, text.ptr, text.len, yellow) orelse {
            return sdlError("TTF_RenderText_Blended");
        };
        defer c.SDL_DestroySurface(surface);

        const previous_texture = self.texture;
        const next_texture = try renderer.createTextureFromSurface(surface);
        if (previous_texture) |texture| {
            renderer.destroyTexture(texture);
        }
        self.texture = next_texture;
        self.texture_width = @intCast(surface.*.w);
        self.texture_height = @intCast(surface.*.h);
    }

    fn destroyTexture(self: *FpsCounter, renderer: *Renderer) void {
        if (self.texture) |texture| {
            renderer.destroyTexture(texture);
            self.texture = null;
            self.texture_width = 0;
            self.texture_height = 0;
        }
    }
};

fn openSystemFont() !*c.TTF_Font {
    const paths = [_][:0]const u8{
        "/System/Library/Fonts/SFNSMono.ttf",
        "/System/Library/Fonts/Menlo.ttc",
        "/Library/Fonts/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSansMono.ttf",
    };

    for (paths) |path| {
        if (c.TTF_OpenFont(path.ptr, font_size)) |font| {
            return font;
        }
    }

    std.log.err("failed to open a system font for the FPS counter", .{});
    return error.SdlError;
}

fn sdlError(comptime operation: []const u8) error{SdlError} {
    return sdl.sdlError(operation);
}
