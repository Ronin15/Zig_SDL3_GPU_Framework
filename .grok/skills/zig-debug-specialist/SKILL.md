---
name: zig-debug-specialist
description: >
  Zig game engine debugging specialist. Use when asked to diagnose or fix Zig
  build failures, test failures, shader compilation errors, SDL3 linking/runtime
  errors, SDL_GPU device or swapchain failures, asset loading problems, frame
  pacing or performance regressions, input/state bugs, crashes, leaks, or
  display-gated GPU smoke failures. Also use when running /zig-debug-specialist.
when-to-use: >
  Debug or investigate failures: zig build errors, test failures, shader
  compilation, SDL init/linking, GPU device/swapchain problems, asset loading,
  frame pacing, performance regressions, input or state bugs, crashes, or
  gpu-smoke issues. Triage, reproduce, and fix root causes following narrow
  commands and layer ownership.
metadata:
  short-description: "Debug Zig game engine and performance failures"
---

# Zig Debug Specialist

## References

This skill has a companion detailed guide. At the start of any task that mentions the reference, resolve its location from the skill file itself:

1. The conversation/system context supplies the absolute filesystem path to this `SKILL.md`.
2. Compute the directory containing this file.
3. Read the guide with the `read_file` tool using the full path:
   `<that-directory>/references/debug-guide.md`

## Debugging Stance

Classify the failure before changing code. Separate compile errors, link errors, shader/toolchain failures, unit-test failures, runtime SDL errors, asset lookup failures, and display/GPU environment problems. Gather the narrowest evidence that distinguishes those categories.

Treat performance regressions as debuggable failures. Separate CPU frame-time,
GPU submission/swapchain, allocation/resource churn, logging overhead, asset/text
lookup, shader/toolchain, and frame-pacing policy before changing code.

Prefer small reproduction commands and targeted file inspection. Do not broaden the fix until the failing layer is clear.

Read the reference guide (see the References section above) when a failure involves build steps, SDL linkage, shader tools, assets, GPU smoke, frame pacing, input/state behavior, or runtime SDL errors.

## Coordination

Diagnose and fix the confirmed failure first. Recommend `zig-review-specialist` after the fix when regression risk, ownership drift, resource lifetime, or performance impact should be reviewed.

## Triage Workflow

1. Capture the exact command, failure text, and whether it is build-time, test-time, or runtime.
2. Identify the owning layer: build, app flow, rendering, game state, platform integration, assets, or tests.
3. Run the narrowest relevant command before wider validation.
4. Inspect the owner file and adjacent tests or build steps.
5. Form one concrete hypothesis and test it.
6. When fixing a runtime or integration failure, add or preserve scoped `std.log` diagnostics at the runtime boundary if they would make the same failure diagnosable next time. Keep debug logs useful but minimal in hot paths, and keep `warn`/`err` rare and actionable.
7. Fix only the confirmed issue, then rerun the failing command.
8. Escalate to broader validation only after the targeted failure is resolved.

For performance failures, first identify the hot path and whether the regression
comes from allocation, repeated lookup/validation, dynamic dispatch, formatted
logging, resource recreation, excessive GPU submissions, or frame pacing. Prefer
moving work to initialization, asset loading, state transitions, or explicit
caches over adding per-frame workarounds.

## Command Selection

- Use `zig build test` for Zig unit failures and pure behavior regressions.
- Use `zig build check` for compile/link coverage without running the app.
- Use `zig build shaders` for shader source, shader tool, or install-path failures.
- Use `zig build dev` or `zig build run` only when runtime behavior needs the app.
- Use `zig build gpu-smoke` for SDL_GPU device/swapchain frame submission checks when a display is available.
- Use `zig build verify` after a fix that affects multiple layers.

Report display, GPU, or sandbox limitations separately from code failures.

## Common Failure Boundaries

- Zig compiler errors usually point to type, import, build option, or API drift.
- Link errors usually point to SDL3/SDL3_ttf discovery, system packages, or build wiring.
- Shader failures usually point to `glslc`, `spirv-cross`, shader source, platform format, or installed asset paths.
- Runtime asset failures usually point to asset-root configuration, install steps, traversal checks, or executable-relative lookup.
- SDL_GPU smoke failures may be code bugs, missing display backend, missing Vulkan/Metal support, or driver setup.
- Input/state bugs usually need event routing, frame commands, held input, state policy, and transition timing checked separately.
- Performance failures usually need CPU, GPU, allocation, logging, resource lifetime, and frame-pacing causes separated before choosing a fix.
