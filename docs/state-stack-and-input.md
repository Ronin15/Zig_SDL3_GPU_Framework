# State Stack And Input

## State Shape

Create a state struct with the methods used by `src/app/state.zig`:

```zig
const state_mod = @import("../app/state.zig");
const RenderContext = state_mod.RenderContext;
const StateTransitions = state_mod.StateTransitions;
const UpdateContext = state_mod.UpdateContext;
const c = @import("../platform/sdl.zig").c;

pub const MyState = struct {
    pub fn init() MyState {
        return .{};
    }

    pub fn deinit(self: *MyState) void {
        _ = self;
    }

    pub fn handleEvent(
        self: *MyState,
        event: *const c.SDL_Event,
        transitions: *StateTransitions,
    ) !bool {
        _ = self;
        _ = event;
        _ = transitions;
        return false;
    }

    pub fn update(self: *MyState, context: UpdateContext) !void {
        _ = self;
        _ = context.input;
        _ = context.delta_seconds;
        _ = context.transitions;
        _ = context.thread_system;
    }

    pub fn render(self: *MyState, context: RenderContext) !void {
        _ = self;
        _ = context.renderer;
        _ = context.interpolation_alpha;
        _ = context.thread_system;
    }

    pub fn onPause(self: *MyState) void {
        _ = self;
    }
};
```

Return `true` from `handleEvent` when the state consumes an event.

## Transitions

Use `StateTransitions` from inside a state when a change should happen after the
current dispatch finishes:

```zig
try context.transitions.replaceGameplay(MainMenuState, MainMenuState.init());
try context.transitions.pushModal(PauseMenuState, PauseMenuState.init());
try context.transitions.pushOverlay(HudState, HudState.init());
try context.transitions.pushOpaque(LoadingState, LoadingState.init());
try context.transitions.quit();
```

Use `StateStack` directly only in app/bootstrap code, such as replacing the
startup state in `src/app/engine.zig`.

`StateStack` owns state allocation and destruction. It calls `deinit` when
states are removed or replaced, and destroys remaining states from top to bottom
when the stack shuts down.

## Policies

- `replaceGameplay` installs a normal gameplay/screen state.
- `pushModal` blocks updates and events below it while still rendering lower states.
- `pushOverlay` allows updates, events, and rendering below it.
- `pushOpaque` blocks rendering below it for full-screen replacement views.

## Input Model

Keyboard input maps to named `Action` values in `src/app/input.zig`.

Held gameplay input:

- `moveLeft`
- `moveRight`
- `moveUp`
- `moveDown`

One-frame commands:

- `pause`
- `resumeGame`
- `quit`
- `toggleDebugOverlay`

Default bindings are:

- WASD for movement
- P for pause
- Enter or Space for resume
- Escape for quit
- F2 for the debug overlay

Gameplay code should read movement through `InputState`, usually from the
`UpdateContext`. App-level commands should stay in `FrameCommands` and engine
coordination code.
