---
name: zig-specialist
description: >
  Zig game engine implementation specialist for SDL3/SDL_GPU-style projects.
  Use when asked to change Zig code, build wiring, tests, shaders, SDL3/SDL_GPU
  integration, app flow, state stack behavior, input routing, rendering, assets,
  frame pacing, pause policy, performance-sensitive paths, or related game-engine
  implementation details. Also use when running /zig-specialist.
when-to-use: >
  Implement features, modify code in src/, update build.zig or shaders, work on
  the engine loop, DataSystem, processors, rendering, input, state stack, assets,
  frame pacing, or any gameplay/engine behavior changes. Follow ownership
  boundaries, performance rules, and validation commands. Add tests or debug
  integration issues.
metadata:
  short-description: "Implement performance-aware Zig SDL3 game changes"
---

# Zig Specialist

## References

This skill has a companion detailed guide. At the start of any task that mentions the reference, resolve its location from the skill file itself:

1. The conversation/system context supplies the absolute filesystem path to this `SKILL.md`.
2. Compute the directory containing this file.
3. Read the guide with the `read_file` tool using the full path:
   `<that-directory>/references/framework-guide.md`

## Operating Mode

Start by reading the relevant files and current behavior before proposing or editing. Treat the codebase as a normal 2D game project. Prefer existing patterns over new abstractions unless the change clearly removes real complexity or unlocks an intended extension point.

Keep changes scoped, performance-critical, and SDL_GPU-first. Do not introduce new dependencies unless the user explicitly asks or the existing standard library/SDL3 path cannot reasonably solve the task.

For engine conventions, commands, and pitfalls, read the reference guide (see the References section above) when a task touches more than one ownership boundary, build/test behavior, rendering, state flow, assets, or shaders.

When implementing a roadmap slice, treat it as a full feature. Do not mark a slice complete unless runtime behavior, diagnostics, docs, tests, and acceptance checks are all integrated. If a dependency does not exist yet, call the work foundation or preparation and leave the feature checklist incomplete.

## Coordination

Use `zig-design-specialist` before implementation when a task changes
architecture, roadmap slices, `DataSystem`, processor contracts, deferred
structural changes, or emergent gameplay flow. Use `zig-review-specialist` for
code-review passes over completed diffs. Use `zig-debug-specialist` when a
build, test, shader, SDL, GPU, asset, input, or runtime failure must be
diagnosed before implementation.

## Ownership Boundaries

Place code in the layer that owns the behavior:

- `src/main.zig`: executable entry and high-level fixed-step timing loop only.
- `src/app/`: engine coordination, state stack, input routing, pause policy, timing, and frame pacing.
- `src/render/`: SDL_GPU renderer, camera, resources, text, and debug overlay.
- `src/game/`: game/demo states, gameplay behavior, `DataSystem`, and ECS-style gameplay systems/processors.
- `src/platform/`: SDL/platform integration helpers and smoke-test implementation.
- `src/assets/`: runtime asset path resolution and installed asset loading.
- `src/core/`: small shared primitives only.

If a change appears to belong in multiple layers, keep SDL/window/GPU ownership on the app/render/platform side and expose only the small API the game layer needs.

## Implementation Workflow

1. Inspect the existing owner file and adjacent tests before editing.
2. Identify whether the task is app flow, rendering, game behavior, platform integration, assets, or shared primitives.
3. Make the smallest coherent change in the owning layer.
4. Keep Zig imports and names idiomatic: use `const std = @import("std");`, import project declarations directly when that keeps call sites clear, avoid `_mod` suffixes, avoid `const Type = file.Type` bridge aliases, and avoid double names such as `thread.ThreadSystem`.
5. Use a concise lowerCamelCase file namespace only when the call site is clearer as a function or namespace lookup, such as `assets.validateRelativePath(...)`; do not rewrite SDL/C symbols, generated build-option names, or `std.Build` field names.
6. Keep raw input mapped to named actions; keep latched frame commands separate from held gameplay input.
7. Let state-stack policies decide whether lower states receive update, input, or render passes.
8. Preserve fixed-step simulation with varying-refresh rendering; do not add a blanket 60 FPS render cap.
9. Pair SDL resource creation with cleanup close to the creation site.
10. Add scoped `std.log` diagnostics for useful lifecycle, configuration, fallback, and failure context. Keep hot-path debug logging minimal and deliberate, keep `warn`/`err` rare and actionable, and keep pure helpers log-free.
11. Add behavior-focused Zig tests when logic can be tested without opening a window.

## Performance Rules

Treat performance as part of correctness. Before adding work to per-frame,
per-event, per-draw, fixed-step update, input dispatch, renderer submission, or
asset/text lookup paths, identify whether it can be moved to initialization,
asset loading, state transitions, configuration, or an explicit cache.

- Keep hot paths allocation-free unless the allocation is measured, bounded, and intentionally isolated.
- Prefer enums, bitsets, arrays, slices, direct indices, ring buffers, and generational IDs for runtime dispatch and resource lookup.
- Treat `DataSystem` as the persistent gameplay data owner and ECS storage foundation. Entity IDs, component masks, and dense typed SoA component stores live there; ECS systems/processors such as movement, AI, collision, pathfinding, and render preparation should be mostly stateless processors over `DataSystem` slices.
- Keep hot ECS component data in dense SoA columns. Component masks are for membership/query decisions, not a replacement for direct slice iteration in hot processors.
- Keep entity structural changes, state transitions, SDL/GPU calls, asset loading, save/load streaming, and renderer resource ownership out of threaded SIMD processors unless an explicit deferred/main-thread boundary is designed.
- For threaded/SIMD ECS work, document hot SoA column alignment, split worker ranges so workers do not write the same cache line, and use 64-byte padding only for thread-shared records where false sharing is a real risk. Do not pad cold entity slot metadata by default.
- Avoid string-key lookup, hash-map dispatch, broad dynamic dispatch, callback chains, repeated descriptor validation, and formatted logging in hot paths unless justified by measured behavior.
- Preserve fixed-step simulation with varying-refresh rendering; do not add broad frame-rate caps that harm high-refresh displays.
- Keep renderer-facing data prepared, batchable, and handle-based rather than reconstructing resources or lookup state each frame.

## Validation Defaults

Use the narrowest useful check first:

- `zig build test` for unit behavior and reusable module coverage.
- `zig build check` for compile coverage of the game and GPU smoke executable.
- `zig build verify` before considering a larger implementation slice complete.
- `zig build shaders` after shader source or shader build wiring changes.
- `zig build gpu-smoke` only when display/GPU validation is relevant and a usable display environment exists.
- `zig build fmt` only when Zig/build files were edited and formatting is needed.

Report any validation that could not be run, especially display-gated GPU checks.
