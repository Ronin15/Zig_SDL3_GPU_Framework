// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AssetStore = @import("assets.zig").AssetStore;
const build_options = @import("build_options");
const config = @import("config.zig");
const DemoState = @import("demo_state.zig").DemoState;
const FpsCounter = @import("fps_counter.zig").FpsCounter;
const frame_pacer = @import("frame_pacer.zig");
const InputState = @import("input.zig").InputState;
const PauseState = @import("pause_state.zig").PauseState;
const Renderer = @import("renderer.zig").Renderer;
const State = @import("state.zig").State;
const StateStack = @import("state.zig").StateStack;
const TimeLoop = @import("time_loop.zig").TimeLoop;
const sdl = @import("sdl.zig");
const c = sdl.c;

pub fn main(init: std.process.Init) !void {
    const app_config = config.AppConfig{
        .app_name = build_options.app_name,
        .window_title = build_options.window_title,
        .asset_root = build_options.asset_root,
        .gpu_debug = build_options.gpu_debug,
    };
    const window_title: [:0]const u8 = app_config.window_title ++ "\x00";

    var sdl_context = try sdl.SdlContext.init(c.SDL_INIT_VIDEO);
    defer sdl_context.deinit();

    var window = try sdl.Window.create(
        window_title,
        app_config.logical_width,
        app_config.logical_height,
        if (app_config.resizable) c.SDL_WINDOW_RESIZABLE else 0,
    );
    defer window.deinit();

    const allocator = init.gpa;
    const assets = AssetStore.init(allocator, init.io, app_config.asset_root);
    var renderer = try Renderer.init(allocator, window.handle, assets, app_config);
    defer renderer.deinit();

    var fps_counter = try FpsCounter.init();
    defer fps_counter.deinit(&renderer);

    var demo_state = DemoState.init(
        @floatFromInt(app_config.logical_width),
        @floatFromInt(app_config.logical_height),
    );
    var states = StateStack.init(allocator);
    try states.replace(State.from(DemoState, &demo_state));
    defer states.deinit();

    var pause_state = PauseState.init(
        @floatFromInt(app_config.logical_width),
        @floatFromInt(app_config.logical_height),
    );
    var gameplay_paused = false;

    var input = InputState{};
    var time_loop = TimeLoop.init(c.SDL_GetTicksNS());
    var running = true;
    while (running) {
        const frame_start_ns = c.SDL_GetTicksNS();
        input.beginFrame();

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    input.handleEvent(&event);
                    states.handleEvent(&event);
                },
                c.SDL_EVENT_KEY_UP => {
                    input.handleEvent(&event);
                    states.handleEvent(&event);
                },
                else => states.handleEvent(&event),
            }
        }
        if (input.fps_toggle_requested) fps_counter.toggle();
        if (input.quit_requested) running = false;
        if (!running) break;

        const frame_policy = frame_pacer.windowFramePolicy(window.handle);
        if (frame_policy.should_pause_gameplay and !gameplay_paused) {
            input.releaseMovement();
            try states.push(State.from(PauseState, &pause_state));
            gameplay_paused = true;
        } else if (gameplay_paused and input.resume_requested and !frame_policy.should_pause_gameplay) {
            states.pop();
            gameplay_paused = false;
        }

        const frame_time_ns = c.SDL_GetTicksNS();
        const frame_delta_ns = if (frame_time_ns > time_loop.last_time_ns) frame_time_ns - time_loop.last_time_ns else 0;
        time_loop.beginFrame(frame_time_ns);
        try fps_counter.update(&renderer, frame_delta_ns);

        while (time_loop.shouldUpdate()) {
            states.update(&input, TimeLoop.fixed_delta_seconds);
            time_loop.finishUpdate();
        }

        if (frame_policy.can_render) {
            renderer.beginFrame(app_config.clear_color);
            try states.render(&renderer, time_loop.interpolationAlpha());
            try fps_counter.render(&renderer);
            switch (try renderer.endFrame()) {
                .submitted => {
                    if (frame_policy.target_frame_ns) |target_frame_ns| {
                        frame_pacer.paceTargetFrame(frame_start_ns, target_frame_ns);
                    }
                },
                .skipped_no_swapchain => {
                    if (!gameplay_paused) {
                        input.releaseMovement();
                        try states.push(State.from(PauseState, &pause_state));
                        gameplay_paused = true;
                    }
                    frame_pacer.paceFallbackFrame(frame_start_ns);
                },
            }
        } else {
            frame_pacer.paceFallbackFrame(frame_start_ns);
        }
    }
}
