const std = @import("std");

pub const AssetStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) AssetStore {
        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
        };
    }

    pub fn readAlloc(self: AssetStore, relative_path: []const u8, max_bytes: usize) ![]u8 {
        const primary_path = try self.resolvePath(relative_path);
        defer self.allocator.free(primary_path);

        return std.Io.Dir.cwd().readFileAlloc(self.io, primary_path, self.allocator, .limited(max_bytes)) catch |err| switch (err) {
            error.FileNotFound => try self.readExeRelativeAlloc(relative_path, max_bytes),
            else => err,
        };
    }

    pub fn resolvePath(self: AssetStore, relative_path: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.root, relative_path });
    }

    fn readExeRelativeAlloc(self: AssetStore, relative_path: []const u8, max_bytes: usize) ![]u8 {
        const exe_dir = try std.process.executableDirPathAlloc(self.io, self.allocator);
        defer self.allocator.free(exe_dir);

        const exe_relative_path = try std.fs.path.join(self.allocator, &.{ exe_dir, self.root, relative_path });
        defer self.allocator.free(exe_relative_path);

        return std.Io.Dir.cwd().readFileAlloc(self.io, exe_relative_path, self.allocator, .limited(max_bytes));
    }
};

test "asset paths are rooted under configured asset directory" {
    const allocator = std.testing.allocator;
    const assets = AssetStore.init(allocator, std.testing.io, "assets");

    const path = try assets.resolvePath("shaders/sprite.vert.spv");
    defer allocator.free(path);

    try std.testing.expectEqualStrings("assets/shaders/sprite.vert.spv", path);
}
