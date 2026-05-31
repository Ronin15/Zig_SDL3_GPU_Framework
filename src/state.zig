// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const InputState = @import("input.zig").InputState;
const Renderer = @import("renderer.zig").Renderer;
const c = @import("sdl.zig").c;

pub const State = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (*anyopaque) void,
        handle_event: *const fn (*anyopaque, *const c.SDL_Event) void,
        update: *const fn (*anyopaque, *const InputState, f32) void,
        render: *const fn (*anyopaque, *Renderer, f32) anyerror!void,
    };

    /// Adapts a borrowed state value. The caller owns the pointed-to state and
    /// must keep it alive until the StateStack removes or deinitializes it.
    pub fn from(comptime T: type, ptr: *T) State {
        const Adapter = struct {
            fn adapterDeinit(state_ptr: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                self.deinit();
            }

            fn adapterHandleEvent(state_ptr: *anyopaque, event: *const c.SDL_Event) void {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                self.handleEvent(event);
            }

            fn adapterUpdate(state_ptr: *anyopaque, input: *const InputState, delta_seconds: f32) void {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                self.update(input, delta_seconds);
            }

            fn adapterRender(state_ptr: *anyopaque, renderer: *Renderer, interpolation_alpha: f32) anyerror!void {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                try self.render(renderer, interpolation_alpha);
            }

            const vtable = VTable{
                .deinit = adapterDeinit,
                .handle_event = adapterHandleEvent,
                .update = adapterUpdate,
                .render = adapterRender,
            };
        };

        return .{
            .ptr = ptr,
            .vtable = &Adapter.vtable,
        };
    }

    pub fn deinit(self: State) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn handleEvent(self: State, event: *const c.SDL_Event) void {
        self.vtable.handle_event(self.ptr, event);
    }

    pub fn update(self: State, input: *const InputState, delta_seconds: f32) void {
        self.vtable.update(self.ptr, input, delta_seconds);
    }

    pub fn render(self: State, renderer: *Renderer, interpolation_alpha: f32) !void {
        try self.vtable.render(self.ptr, renderer, interpolation_alpha);
    }
};

pub const StateStack = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayList(State) = .empty,

    pub fn init(allocator: std.mem.Allocator) StateStack {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StateStack) void {
        while (self.states.pop()) |state| {
            state.deinit();
        }
        self.states.deinit(self.allocator);
    }

    pub fn push(self: *StateStack, state: State) !void {
        try self.states.append(self.allocator, state);
    }

    pub fn pop(self: *StateStack) void {
        if (self.states.pop()) |state| {
            state.deinit();
        }
    }

    pub fn replace(self: *StateStack, state: State) !void {
        try self.states.ensureTotalCapacity(self.allocator, 1);
        self.clear();
        self.states.appendAssumeCapacity(state);
    }

    pub fn active(self: *StateStack) ?State {
        if (self.states.items.len == 0) return null;
        return self.states.items[self.states.items.len - 1];
    }

    fn clear(self: *StateStack) void {
        while (self.states.pop()) |state| {
            state.deinit();
        }
    }

    pub fn handleEvent(self: *StateStack, event: *const c.SDL_Event) void {
        if (self.active()) |state| {
            state.handleEvent(event);
        }
    }

    pub fn update(self: *StateStack, input: *const InputState, delta_seconds: f32) void {
        if (self.active()) |state| {
            state.update(input, delta_seconds);
        }
    }

    pub fn render(self: *StateStack, renderer: *Renderer, interpolation_alpha: f32) !void {
        for (self.states.items) |state| {
            try state.render(renderer, interpolation_alpha);
        }
    }
};

test "state stack push pop and replace maintain active state" {
    const TestingState = struct {
        id: u32,
        deinit_count: *u32,

        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }

        fn handleEvent(self: *@This(), event: *const c.SDL_Event) void {
            _ = self;
            _ = event;
        }

        fn update(self: *@This(), input: *const InputState, delta_seconds: f32) void {
            _ = self;
            _ = input;
            _ = delta_seconds;
        }

        fn render(self: *@This(), renderer: *Renderer, interpolation_alpha: f32) !void {
            _ = self;
            _ = renderer;
            _ = interpolation_alpha;
        }
    };

    var deinit_count: u32 = 0;
    var first = TestingState{ .id = 1, .deinit_count = &deinit_count };
    var second = TestingState{ .id = 2, .deinit_count = &deinit_count };

    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(State.from(TestingState, &first));
    try std.testing.expect(stack.active().?.ptr == @as(*anyopaque, @ptrCast(&first)));

    try stack.push(State.from(TestingState, &second));
    try std.testing.expect(stack.active().?.ptr == @as(*anyopaque, @ptrCast(&second)));

    stack.pop();
    try std.testing.expectEqual(@as(u32, 1), deinit_count);
    try std.testing.expect(stack.active().?.ptr == @as(*anyopaque, @ptrCast(&first)));

    try stack.replace(State.from(TestingState, &second));
    try std.testing.expectEqual(@as(u32, 2), deinit_count);
    try std.testing.expect(stack.active().?.ptr == @as(*anyopaque, @ptrCast(&second)));
}
