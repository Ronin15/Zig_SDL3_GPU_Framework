# SDL3 Zig Game Template

A Zig 0.16.0 + SDL3 starting point for SDL_GPU-first 2D game development.

## Requirements

- Zig 0.16.0
- SDL3 development headers and library discoverable by the compiler/linker

SDL3 is a system dependency. Install your platform's SDL3 development package so `SDL3/SDL.h` and `libSDL3` are available. On this machine that package is `sdl3` via pacman.

## Commands

```sh
zig build dev       # normal edit/run loop; compiles shaders and installs assets
zig build check     # compile game and GPU smoke executable without running
zig build test      # run unit tests
zig build verify    # run check, test, and shader compilation
zig build package   # install binaries and runtime assets into zig-out/bin
```

Useful supporting commands:

```sh
zig build fmt       # format build.zig and src/
zig build shaders   # compile GLSL shader sources to SPIR-V
zig build gpu-smoke # create an SDL_GPU device and submit one hidden-window frame
```

The default build mode is `ReleaseSafe` so the template links cleanly on current Linux toolchains while keeping runtime safety checks. Override it with `zig build -Doptimize=ReleaseFast`, `ReleaseSmall`, or `Debug` when your local Zig/toolchain combination supports it.

Customize app metadata at build time:

```sh
zig build -Dapp-name=my-game -Dwindow-title="My Game"
```

## Render Flow

The app uses SDL_GPU directly, not `SDL_Renderer`, and it does not call Vulkan itself.

- Shader sources live in `assets/shaders/*.glsl`.
- The Zig build compiles GLSL to SPIR-V with `glslc`.
- Compiled shader binaries are installed as `zig-out/bin/assets/shaders/*.spv`.
- `src/renderer.zig` creates an SDL_GPU device with `SDL_GPU_SHADERFORMAT_SPIRV`.
- On Linux, SDL_GPU normally selects its Vulkan backend for SPIR-V shaders.
- Game code draws through `Renderer`; it should not call SDL_GPU directly.
- PNG texture loading uses core SDL3 `SDL_LoadPNG`/`SDL_LoadSurface` support. This project does not use `SDL3_image`.
- Sprites and colored rectangles are collected into a CPU batch, uploaded to one GPU vertex buffer per frame, and submitted by texture/layer groups.

Override the shader compiler path with:

```sh
zig build shaders -Dshader-compiler=/path/to/glslc
```

## Layout

- `src/main.zig` owns SDL startup, the window, event polling, and the main loop.
- `src/renderer.zig` owns SDL_GPU device setup, swapchain rendering, shader loading, texture upload, and the batched 2D draw API.
- `src/scene.zig` defines the push/pop scene stack used for gameplay, menus, tools, and overlays.
- `src/demo_scene.zig` contains the initial movable-player scene.
- `src/input.zig` converts SDL input events into a frame-stable input state.
- `src/assets.zig` resolves runtime asset paths and loads installed shader/data files.
- `src/camera.zig` contains the 2D camera transform used by the renderer.
- `src/config.zig` centralizes app/window/GPU configuration.
- `src/time_loop.zig` provides a fixed 60Hz simulation loop with interpolation.
- `src/root.zig` contains reusable game-agnostic helpers and unit tests.
- `assets/` is copied to `zig-out/bin/assets` during install/build.

Use scenes as coarse app states, then split larger gameplay into small systems/modules under `src/`. Gameplay code should draw through `Renderer` instead of calling SDL_GPU directly.

## Adding A Scene

Create a struct with this shape and push or replace it through `SceneStack`:

```zig
pub fn deinit(self: *MyScene) void {}
pub fn handleEvent(self: *MyScene, event: *const c.SDL_Event) void {}
pub fn update(self: *MyScene, input: *const InputState, delta_seconds: f32) void {}
pub fn render(self: *MyScene, renderer: *Renderer, alpha: f32) !void {}
```

Use `try scenes.push(Scene.from(MyScene, &my_scene))` for overlays and `try scenes.replace(...)` for full state changes.

## Adding Art

Put PNGs under `assets/`, then load them through the renderer after it is initialized:

```zig
const texture = try renderer.createTextureFromPng(assets, "sprites/player.png");
```

Draw using `drawSprite`:

```zig
try renderer.drawSprite(.{
    .texture = texture,
    .dest = .{ .x = 100, .y = 120, .w = 32, .h = 32 },
    .layer = 0,
});
```

Use `drawRect` for debug or simple primitive rendering. It goes through the same sprite batch via a built-in white texture.

## Adding A Shader

Add GLSL source under `assets/shaders/`, extend `addShaderSteps` in `build.zig`, and load the resulting `.spv` from `src/renderer.zig`. Keep shader resource bindings aligned with SDL_GPU's SPIR-V layout rules:

- vertex uniform buffers: set 1
- fragment sampled textures/samplers: set 2
- fragment uniform buffers: set 3
