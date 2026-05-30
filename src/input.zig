// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const c = @import("sdl.zig").c;

pub const InputState = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,

    pub fn handleEvent(self: *InputState, event: *const c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                const pressed = event.type == c.SDL_EVENT_KEY_DOWN;
                switch (event.key.key) {
                    c.SDLK_A => self.left = pressed,
                    c.SDLK_D => self.right = pressed,
                    c.SDLK_W => self.up = pressed,
                    c.SDLK_S => self.down = pressed,
                    else => {},
                }
            },
            else => {},
        }
    }
};
