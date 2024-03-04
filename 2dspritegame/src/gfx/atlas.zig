const std = @import("std");
const Sprite = @import("sprite.zig").Sprite;
const Animation = @import("animation.zig").Animation;

pub const Atlas = struct {
    sprites: []Sprite,
    animations: []Animation,

    pub fn initFromFile(allocator: std.mem.Allocator, file: [:0]const u8) !Atlas {
        const file_path = try std.fs.realpathAlloc(allocator, file);
        defer allocator.free(file_path);

        const file_to_open = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
        defer file_to_open.close();

        const file_size = (try file_to_open.stat()).size;
        const buffer = try allocator.alloc(u8, file_size);
        defer allocator.free(buffer);

        try file_to_open.reader().readNoEof(buffer);

        const options = std.json.ParseOptions{ .duplicate_field_behavior = .use_first, .ignore_unknown_fields = true };
        const parsed = std.json.parseFromSlice(Atlas, allocator, buffer, options) catch {
            try std.fs.cwd().writeFile("test.json", buffer);
            return error.F;
        };
        defer parsed.deinit();

        return .{
            .sprites = try allocator.dupe(Sprite, parsed.value.sprites),
            .animations = try allocator.dupe(Animation, parsed.value.animations),
        };
    }
};