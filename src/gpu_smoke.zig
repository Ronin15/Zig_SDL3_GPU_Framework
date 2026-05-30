// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AssetStore = @import("assets.zig").AssetStore;
const config = @import("config.zig");
const Renderer = @import("renderer.zig").Renderer;
const c = @import("sdl.zig").c;

pub fn main(init: std.process.Init) !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        return sdlError("SDL_Init");
    }
    defer c.SDL_Quit();

    const title = "SDL_GPU Smoke\x00";
    const window = c.SDL_CreateWindow(title.ptr, 320, 180, c.SDL_WINDOW_HIDDEN) orelse {
        return sdlError("SDL_CreateWindow");
    };
    defer c.SDL_DestroyWindow(window);

    const app_config = config.AppConfig{
        .app_name = "gpu-smoke",
        .window_title = "SDL_GPU Smoke",
        .gpu_debug = true,
    };
    const assets = AssetStore.init(init.gpa, init.io, app_config.asset_root);

    var renderer = try Renderer.init(init.gpa, window, assets, app_config);
    defer renderer.deinit();

    if (try renderer.beginFrame(app_config.clear_color)) {
        try renderer.drawRect(.{ .x = 32, .y = 32, .w = 64, .h = 64 }, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 0);
        try renderer.endFrame();
    }
}

fn sdlError(comptime operation: []const u8) error{SdlError} {
    std.log.err("{s} failed: {s}", .{ operation, c.SDL_GetError() });
    return error.SdlError;
}
