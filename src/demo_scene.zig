const core = @import("sdl3_Template");
const config = @import("config.zig");
const InputState = @import("input.zig").InputState;
const Renderer = @import("renderer.zig").Renderer;
const Rect = @import("renderer.zig").Rect;
const Sprite = @import("renderer.zig").Sprite;
const TextureHandle = @import("renderer.zig").TextureHandle;
const c = @import("sdl.zig").c;

pub const DemoScene = struct {
    player: core.Vec2 = .{ .x = 400, .y = 225 },
    previous_player: core.Vec2 = .{ .x = 400, .y = 225 },
    bounds_width: f32 = 800,
    bounds_height: f32 = 450,
    player_texture: TextureHandle,

    const player_size: f32 = 32;
    const player_speed: f32 = 240;

    pub fn init(bounds_width: f32, bounds_height: f32, player_texture: TextureHandle) DemoScene {
        return .{
            .bounds_width = bounds_width,
            .bounds_height = bounds_height,
            .player_texture = player_texture,
        };
    }

    pub fn deinit(self: *DemoScene) void {
        _ = self;
    }

    pub fn handleEvent(self: *DemoScene, event: *const c.SDL_Event) void {
        _ = self;
        _ = event;
    }

    pub fn update(self: *DemoScene, input: *const InputState, delta_seconds: f32) void {
        self.previous_player = self.player;

        var direction = core.Vec2{};
        if (input.left) direction.x -= 1;
        if (input.right) direction.x += 1;
        if (input.up) direction.y -= 1;
        if (input.down) direction.y += 1;

        self.player.x = core.clamp(
            self.player.x + direction.x * player_speed * delta_seconds,
            0,
            self.bounds_width - player_size,
        );
        self.player.y = core.clamp(
            self.player.y + direction.y * player_speed * delta_seconds,
            0,
            self.bounds_height - player_size,
        );
    }

    pub fn render(self: *DemoScene, renderer: *Renderer, interpolation_alpha: f32) !void {
        const render_player = core.lerpVec2(self.previous_player, self.player, interpolation_alpha);
        try renderer.drawSprite(Sprite{
            .texture = self.player_texture,
            .dest = .{
                .x = render_player.x,
                .y = render_player.y,
                .w = player_size,
                .h = player_size,
            },
        });
        try renderer.drawRect(.{
            .x = 0,
            .y = self.bounds_height - 4,
            .w = self.bounds_width,
            .h = 4,
        }, config.Color{ .r = 0.16, .g = 0.24, .b = 0.29, .a = 1.0 }, -1);
    }
};
