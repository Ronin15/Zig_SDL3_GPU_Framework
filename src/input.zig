// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const c = @import("sdl.zig").c;

pub const InputState = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    quit_requested: bool = false,
    fps_toggle_requested: bool = false,
    pause_toggle_requested: bool = false,
    resume_requested: bool = false,

    pub fn beginFrame(self: *InputState) void {
        self.quit_requested = false;
        self.fps_toggle_requested = false;
        self.pause_toggle_requested = false;
        self.resume_requested = false;
    }

    pub fn releaseMovement(self: *InputState) void {
        self.left = false;
        self.right = false;
        self.up = false;
        self.down = false;
    }

    pub fn handleEvent(self: *InputState, event: *const c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                self.handleKey(
                    event.key.key,
                    event.type == c.SDL_EVENT_KEY_DOWN,
                    event.key.repeat,
                );
            },
            else => {},
        }
    }

    fn handleKey(self: *InputState, key: c.SDL_Keycode, pressed: bool, repeat: bool) void {
        switch (key) {
            c.SDLK_A => self.left = pressed,
            c.SDLK_D => self.right = pressed,
            c.SDLK_W => self.up = pressed,
            c.SDLK_S => self.down = pressed,
            c.SDLK_ESCAPE => self.quit_requested = pressed and !repeat,
            c.SDLK_F2 => self.fps_toggle_requested = pressed and !repeat,
            c.SDLK_P => self.pause_toggle_requested = pressed and !repeat,
            c.SDLK_RETURN, c.SDLK_SPACE => self.resume_requested = pressed and !repeat,
            else => {},
        }
    }
};

test "input key mapping tracks key down and key up" {
    const std = @import("std");
    var input = InputState{};

    input.handleKey(c.SDLK_A, true, false);
    input.handleKey(c.SDLK_W, true, false);
    try std.testing.expect(input.left);
    try std.testing.expect(input.up);
    try std.testing.expect(!input.right);
    try std.testing.expect(!input.down);

    input.handleKey(c.SDLK_A, false, false);
    try std.testing.expect(!input.left);
    try std.testing.expect(input.up);
}

test "input ignores unmapped keys" {
    const std = @import("std");
    var input = InputState{ .right = true };

    input.handleKey(c.SDLK_SPACE, true, false);
    try std.testing.expect(input.right);
    try std.testing.expect(!input.left);
}

test "input maps non-repeated key down events to frame commands" {
    const std = @import("std");
    var input = InputState{};

    input.handleKey(c.SDLK_F2, true, false);
    input.handleKey(c.SDLK_P, true, false);
    input.handleKey(c.SDLK_ESCAPE, true, false);
    input.handleKey(c.SDLK_RETURN, true, false);
    try std.testing.expect(input.fps_toggle_requested);
    try std.testing.expect(input.pause_toggle_requested);
    try std.testing.expect(input.quit_requested);
    try std.testing.expect(input.resume_requested);

    input.beginFrame();
    try std.testing.expect(!input.fps_toggle_requested);
    try std.testing.expect(!input.pause_toggle_requested);
    try std.testing.expect(!input.quit_requested);
    try std.testing.expect(!input.resume_requested);
}

test "input ignores repeated command keys" {
    const std = @import("std");
    var input = InputState{};

    input.handleKey(c.SDLK_F2, true, true);
    input.handleKey(c.SDLK_P, true, true);
    input.handleKey(c.SDLK_ESCAPE, true, true);
    input.handleKey(c.SDLK_RETURN, true, true);

    try std.testing.expect(!input.fps_toggle_requested);
    try std.testing.expect(!input.pause_toggle_requested);
    try std.testing.expect(!input.quit_requested);
    try std.testing.expect(!input.resume_requested);
}

test "input can release held movement when gameplay is paused" {
    const std = @import("std");
    var input = InputState{ .left = true, .right = true, .up = true, .down = true };

    input.releaseMovement();

    try std.testing.expect(!input.left);
    try std.testing.expect(!input.right);
    try std.testing.expect(!input.up);
    try std.testing.expect(!input.down);
}
