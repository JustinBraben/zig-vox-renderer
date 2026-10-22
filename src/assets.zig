//! Files installed next to the executable under `assets/` (see build.zig): compiled
//! shaders in `shaders/`, textures in `textures/`. Paths are resolved against the
//! executable's directory, so it runs from any working directory.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.assets);

const Self = @This();

/// Largest file `read` accepts.
const max_file_size = 256 * 1024 * 1024;

io: std.Io,
gpa: Allocator,
/// `<exe dir>/assets`
dir: std.Io.Dir,

pub fn init(io: std.Io, gpa: Allocator) !Self {
    const exe_dir = try std.process.executableDirPathAlloc(io, gpa);
    defer gpa.free(exe_dir);
    const path = try std.fs.path.join(gpa, &.{ exe_dir, "assets" });
    defer gpa.free(path);

    const dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch |err| {
        log.err("assets not found at {s}: {s} (run `zig build` to install them)", .{ path, @errorName(err) });
        return error.AssetsNotFound;
    };
    log.info("loading assets from {s}", .{path});
    return .{ .io = io, .gpa = gpa, .dir = dir };
}

pub fn deinit(self: *Self) void {
    self.dir.close(self.io);
}

/// Reads `assets/<path>`; free the result with `self.gpa`.
pub fn read(self: *const Self, path: []const u8) ![]u8 {
    return self.dir.readFileAlloc(self.io, path, self.gpa, .limited(max_file_size)) catch |err| {
        log.err("reading assets/{s} failed: {s}", .{ path, @errorName(err) });
        return err;
    };
}

/// Reads the SPIR-V for `name` (e.g. "voxel.vert"); free the result with `self.gpa`.
pub fn readShader(self: *const Self, name: []const u8) ![]align(@alignOf(u32)) u8 {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "shaders/{s}.spv", .{name});
    return self.dir.readFileAllocOptions(self.io, path, self.gpa, .limited(max_file_size), .of(u32), null) catch |err| {
        log.err("reading assets/{s} failed: {s}", .{ path, @errorName(err) });
        return err;
    };
}
