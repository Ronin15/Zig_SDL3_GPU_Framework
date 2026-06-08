// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const runner = @import("benchmarks/runner.zig");

pub const std_options = runner.std_options;

pub fn main(init: std.process.Init) !void {
    try runner.main(init);
}
