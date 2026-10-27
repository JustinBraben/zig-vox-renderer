//! Saved worlds: the edited chunks and the player, one folder per seed
//! (`world-<seed>/`) inside the saves folder.
//!
//! Only chunks that differ from the generated terrain are saved. They are grouped in
//! region files of `region_size`² chunk columns (`r.<x>.<z>.dat`), each read the first
//! time a chunk in it is needed and rewritten by `flush` when one of them changed.
//! Blocks are run-length encoded; light isn't saved, it is recomputed on load.
//!
//! Region file, little endian: "VOXR", u32 version, u32 chunk count, then per chunk
//! i32 x, y, z, u32 byte count and the encoded blocks: runs of (u16 length, u8 block).
//!
//! player.dat, little endian: "VOXP", u32 version, f64 x, y, z, f32 yaw, pitch,
//! time of day, u8 flying; since version 2 also u8 creative, health, selected slot and
//! per hotbar slot u8 block, count.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const chunk = @import("chunk.zig");
const ChunkPos = chunk.ChunkPos;
const BlockId = @import("block.zig").BlockId;
const Inventory = @import("../game/inventory.zig");

const log = std.log.scoped(.save);

const Self = @This();

/// Chunk columns per region side.
pub const region_size = 16;

const region_magic = "VOXR";
const player_magic = "VOXP";
const region_version = 1;
const player_version = 2;
/// Largest file read.
const max_file_size = 64 * 1024 * 1024;

const Region = struct {
    /// a chunk in it changed since it was last written
    dirty: bool = false,
    /// the file couldn't be read; it is never overwritten, to keep what's left of it
    broken: bool = false,
};

/// What `writePlayer` keeps of the player.
pub const Player = struct {
    position: [3]f64,
    yaw: f32,
    pitch: f32,
    flying: bool,
    time_of_day: f32,
    /// version 1 saves predate survival mode, so they load in creative
    creative: bool = true,
    health: u8 = 20,
    inventory: Inventory = .{},
};

io: Io,
allocator: Allocator,
/// the world's folder; null keeps everything in memory only
dir: ?Io.Dir = null,
/// encoded blocks of every saved chunk in the regions read so far
chunks: std.AutoHashMapUnmanaged(ChunkPos, []u8) = .empty,
regions: std.AutoHashMapUnmanaged([2]i32, Region) = .empty,

/// A save that keeps everything in memory.
pub fn memory(io: Io, allocator: Allocator) Self {
    return .{ .io = io, .allocator = allocator };
}

/// Opens (creating it when needed) the world of `seed` inside `saves`.
pub fn open(io: Io, allocator: Allocator, saves: Io.Dir, seed: u64) !Self {
    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "world-{d}", .{seed});
    try saves.createDirPath(io, name);
    const dir = try saves.openDir(io, name, .{});
    return .{ .io = io, .allocator = allocator, .dir = dir };
}

pub fn deinit(self: *Self) void {
    var it = self.chunks.valueIterator();
    while (it.next()) |data| self.allocator.free(data.*);
    self.chunks.deinit(self.allocator);
    self.regions.deinit(self.allocator);
    if (self.dir) |dir| dir.close(self.io);
}

pub fn regionOf(pos: ChunkPos) [2]i32 {
    return .{ @divFloor(pos.x, region_size), @divFloor(pos.z, region_size) };
}

/// The saved blocks of the chunk at `pos`, or null when it isn't saved. Free the
/// result with `allocator`.
pub fn load(self: *Self, allocator: Allocator, pos: ChunkPos) !?*chunk.Blocks {
    try self.readRegion(regionOf(pos));
    const data = self.chunks.get(pos) orelse return null;
    const blocks = try allocator.create(chunk.Blocks);
    errdefer allocator.destroy(blocks);
    decode(data, blocks) catch |err| {
        log.warn("saved chunk {d} {d} {d} is damaged: {t}", .{ pos.x, pos.y, pos.z, err });
        allocator.destroy(blocks);
        return null;
    };
    return blocks;
}

/// Saves the blocks of the chunk at `pos` (`uniform` when `blocks` is null), to be
/// written by the next `flush`.
pub fn store(self: *Self, pos: ChunkPos, blocks: ?*const chunk.Blocks, uniform: BlockId) !void {
    const region = regionOf(pos);
    try self.readRegion(region);
    const data = try encode(self.allocator, blocks, uniform);
    errdefer self.allocator.free(data);
    const entry = try self.chunks.getOrPut(self.allocator, pos);
    if (entry.found_existing) self.allocator.free(entry.value_ptr.*);
    entry.value_ptr.* = data;
    self.regions.getPtr(region).?.dirty = true;
}

/// Writes every region that changed.
pub fn flush(self: *Self) !void {
    const dir = self.dir orelse return;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(self.allocator);
    var it = self.regions.iterator();
    while (it.next()) |entry| {
        const region = entry.value_ptr;
        if (!region.dirty or region.broken) continue;
        data.clearRetainingCapacity();
        try self.encodeRegion(entry.key_ptr.*, &data);
        var name_buf: [64]u8 = undefined;
        const name = regionName(&name_buf, entry.key_ptr.*);
        try writeAtomically(self.io, dir, name, data.items);
        region.dirty = false;
    }
}

pub fn writePlayer(self: *Self, player: Player) !void {
    const dir = self.dir orelse return;
    var data: [player_magic.len + 4 + 3 * 8 + 4 * 3 + 4 + 2 * Inventory.size]u8 = undefined;
    var w: Writer = .{ .buf = &data };
    w.bytes(player_magic);
    w.int(u32, player_version);
    for (player.position) |v| w.int(u64, @bitCast(v));
    w.int(u32, @bitCast(player.yaw));
    w.int(u32, @bitCast(player.pitch));
    w.int(u32, @bitCast(player.time_of_day));
    w.int(u8, @intFromBool(player.flying));
    w.int(u8, @intFromBool(player.creative));
    w.int(u8, player.health);
    w.int(u8, @intCast(player.inventory.selected));
    for (player.inventory.slots) |slot| {
        w.int(u8, @intFromEnum(slot.block));
        w.int(u8, slot.count);
    }
    std.debug.assert(w.at == data.len);
    try writeAtomically(self.io, dir, "player.dat", &data);
}

/// The player as last written, or null when there is none (or it can't be read).
pub fn readPlayer(self: *Self) ?Player {
    const dir = self.dir orelse return null;
    var buf: [128]u8 = undefined;
    const data = dir.readFile(self.io, "player.dat", &buf) catch return null;
    var r: Reader = .{ .data = data };
    const player = readPlayerData(&r) catch {
        log.warn("player.dat is damaged; starting at the spawn point", .{});
        return null;
    };
    for (player.position) |v| if (!std.math.isFinite(v)) return null;
    return player;
}

fn readPlayerData(r: *Reader) !Player {
    if (!std.mem.eql(u8, try r.bytes(player_magic.len), player_magic)) return error.BadMagic;
    const v = try r.int(u32);
    if (v < 1 or v > player_version) return error.UnsupportedVersion;
    var player: Player = .{ .position = undefined, .yaw = undefined, .pitch = undefined, .flying = undefined, .time_of_day = undefined };
    for (&player.position) |*p| p.* = @bitCast(try r.int(u64));
    player.yaw = @bitCast(try r.int(u32));
    player.pitch = @bitCast(try r.int(u32));
    player.time_of_day = @bitCast(try r.int(u32));
    player.flying = try r.int(u8) != 0;
    if (v < 2) return player;
    player.creative = try r.int(u8) != 0;
    player.health = try r.int(u8);
    player.inventory.selected = try r.int(u8);
    for (&player.inventory.slots) |*slot| {
        slot.block = @enumFromInt(try r.int(u8));
        slot.count = try r.int(u8);
    }
    player.inventory.sanitize();
    return player;
}

/// Reads a region file the first time one of its chunks is asked for.
fn readRegion(self: *Self, region: [2]i32) !void {
    const entry = try self.regions.getOrPut(self.allocator, region);
    if (entry.found_existing) return;
    entry.value_ptr.* = .{};
    const dir = self.dir orelse return;
    var name_buf: [64]u8 = undefined;
    const name = regionName(&name_buf, region);
    const data = dir.readFileAlloc(self.io, name, self.allocator, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            log.err("reading {s} failed: {t}; its edits are not loaded", .{ name, err });
            entry.value_ptr.broken = true;
            return;
        },
    };
    defer self.allocator.free(data);
    self.decodeRegion(data) catch |err| {
        log.err("{s} is damaged ({t}); its edits are not loaded", .{ name, err });
        entry.value_ptr.broken = true;
    };
}

fn decodeRegion(self: *Self, data: []const u8) !void {
    var r: Reader = .{ .data = data };
    if (!std.mem.eql(u8, try r.bytes(region_magic.len), region_magic)) return error.BadMagic;
    if (try r.int(u32) != region_version) return error.UnsupportedVersion;
    const count = try r.int(u32);
    for (0..count) |_| {
        const pos: ChunkPos = .{ .x = try r.int(i32), .y = try r.int(i32), .z = try r.int(i32) };
        const encoded = try r.bytes(try r.int(u32));
        const copy = try self.allocator.dupe(u8, encoded);
        errdefer self.allocator.free(copy);
        const entry = try self.chunks.getOrPut(self.allocator, pos);
        if (entry.found_existing) self.allocator.free(entry.value_ptr.*);
        entry.value_ptr.* = copy;
    }
}

fn encodeRegion(self: *const Self, region: [2]i32, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(self.allocator, region_magic);
    try appendInt(self.allocator, out, u32, region_version);
    const count_at = out.items.len;
    try appendInt(self.allocator, out, u32, 0);
    var count: u32 = 0;
    var it = self.chunks.iterator();
    while (it.next()) |entry| {
        const pos = entry.key_ptr.*;
        if (!std.meta.eql(regionOf(pos), region)) continue;
        try appendInt(self.allocator, out, i32, pos.x);
        try appendInt(self.allocator, out, i32, pos.y);
        try appendInt(self.allocator, out, i32, pos.z);
        try appendInt(self.allocator, out, u32, @intCast(entry.value_ptr.len));
        try out.appendSlice(self.allocator, entry.value_ptr.*);
        count += 1;
    }
    std.mem.writeInt(u32, out.items[count_at..][0..4], count, .little);
}

fn regionName(buf: []u8, region: [2]i32) []const u8 {
    return std.fmt.bufPrint(buf, "r.{d}.{d}.dat", .{ region[0], region[1] }) catch unreachable;
}

/// Writes a temporary file and renames it over `name`, so a crash midway never leaves
/// a half-written file.
fn writeAtomically(io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    var tmp_buf: [80]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name});
    try dir.writeFile(io, .{ .sub_path = tmp, .data = data });
    try dir.rename(tmp, dir, name, io);
}

/// Run-length encoded blocks; `uniform` when `blocks` is null.
fn encode(allocator: Allocator, blocks: ?*const chunk.Blocks, uniform: BlockId) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const all = blocks orelse {
        try appendRun(allocator, &out, chunk.volume, uniform);
        return out.toOwnedSlice(allocator);
    };
    var run_start: usize = 0;
    for (1..chunk.volume + 1) |i| {
        if (i < chunk.volume and all[i] == all[run_start]) continue;
        try appendRun(allocator, &out, i - run_start, all[run_start]);
        run_start = i;
    }
    return out.toOwnedSlice(allocator);
}

fn appendRun(allocator: Allocator, out: *std.ArrayList(u8), length: usize, block: BlockId) !void {
    // a whole chunk doesn't fit in a u16
    var left = length;
    while (left > 0) {
        const n = @min(left, std.math.maxInt(u16));
        try appendInt(allocator, out, u16, @intCast(n));
        try out.append(allocator, @intFromEnum(block));
        left -= n;
    }
}

fn decode(data: []const u8, blocks: *chunk.Blocks) !void {
    var r: Reader = .{ .data = data };
    var i: usize = 0;
    while (r.at < data.len) {
        const n = try r.int(u16);
        const block: BlockId = @enumFromInt(try r.int(u8));
        if (n > chunk.volume - i) return error.TooManyBlocks;
        @memset(blocks[i..][0..n], block);
        i += n;
    }
    if (i != chunk.volume) return error.TooFewBlocks;
}

fn appendInt(allocator: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

const Writer = struct {
    buf: []u8,
    at: usize = 0,

    fn bytes(w: *Writer, data: []const u8) void {
        @memcpy(w.buf[w.at..][0..data.len], data);
        w.at += data.len;
    }

    fn int(w: *Writer, comptime T: type, value: T) void {
        std.mem.writeInt(T, w.buf[w.at..][0..@sizeOf(T)], value, .little);
        w.at += @sizeOf(T);
    }
};

const Reader = struct {
    data: []const u8,
    at: usize = 0,

    fn bytes(r: *Reader, n: usize) ![]const u8 {
        if (n > r.data.len - r.at) return error.EndOfData;
        defer r.at += n;
        return r.data[r.at..][0..n];
    }

    fn int(r: *Reader, comptime T: type) !T {
        return std.mem.readInt(T, (try r.bytes(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
};

const testing = std.testing;

fn testBlocks() !*chunk.Blocks {
    const blocks = try testing.allocator.create(chunk.Blocks);
    for (blocks, 0..) |*b, i| b.* = if (i % 7 == 0) .stone else if (i < chunk.volume / 2) .dirt else .air;
    return blocks;
}

test "blocks survive encoding" {
    const blocks = try testBlocks();
    defer testing.allocator.destroy(blocks);
    const data = try encode(testing.allocator, blocks, .air);
    defer testing.allocator.free(data);
    var decoded: chunk.Blocks = undefined;
    try decode(data, &decoded);
    try testing.expectEqualSlices(BlockId, blocks, &decoded);

    // a uniform chunk is longer than one run
    const uniform = try encode(testing.allocator, null, .stone);
    defer testing.allocator.free(uniform);
    try decode(uniform, &decoded);
    try testing.expect(std.mem.allEqual(BlockId, &decoded, .stone));

    try testing.expectError(error.TooFewBlocks, decode(data[0 .. data.len - 3], &decoded));
}

test "saved chunks and the player come back after reopening" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const blocks = try testBlocks();
    defer testing.allocator.destroy(blocks);
    var player: Player = .{ .position = .{ 1.5, 70, -3.25 }, .yaw = 90, .pitch = -10, .flying = true, .time_of_day = 18.5, .creative = false, .health = 7 };
    _ = player.inventory.add(.cobblestone, 70);
    player.inventory.selected = 4;
    {
        var save = try open(testing.io, testing.allocator, tmp.dir, 42);
        defer save.deinit();
        try save.store(.{ .x = -1, .y = 2, .z = 17 }, blocks, .air);
        try save.store(.{ .x = 3, .y = 0, .z = 3 }, null, .planks);
        try save.flush();
        try save.writePlayer(player);
    }
    var save = try open(testing.io, testing.allocator, tmp.dir, 42);
    defer save.deinit();
    const a = (try save.load(testing.allocator, .{ .x = -1, .y = 2, .z = 17 })).?;
    defer testing.allocator.destroy(a);
    try testing.expectEqualSlices(BlockId, blocks, a);
    const b = (try save.load(testing.allocator, .{ .x = 3, .y = 0, .z = 3 })).?;
    defer testing.allocator.destroy(b);
    try testing.expect(std.mem.allEqual(BlockId, b, .planks));
    try testing.expectEqual(null, try save.load(testing.allocator, .{ .x = 3, .y = 1, .z = 3 }));
    try testing.expectEqual(player, save.readPlayer().?);

    // another seed is another world
    var other = try open(testing.io, testing.allocator, tmp.dir, 43);
    defer other.deinit();
    try testing.expectEqual(null, try other.load(testing.allocator, .{ .x = 3, .y = 0, .z = 3 }));
    try testing.expectEqual(null, other.readPlayer());
}

test "a version 1 player loads in creative with full health" {
    var data: [player_magic.len + 4 + 3 * 8 + 4 * 3 + 1]u8 = undefined;
    var w: Writer = .{ .buf = &data };
    w.bytes(player_magic);
    w.int(u32, 1);
    for ([3]f64{ 1, 2, 3 }) |v| w.int(u64, @bitCast(v));
    for ([3]f32{ 10, 20, 6 }) |v| w.int(u32, @bitCast(v));
    w.int(u8, 1);
    var r: Reader = .{ .data = &data };
    const player = try readPlayerData(&r);
    try testing.expectEqual([3]f64{ 1, 2, 3 }, player.position);
    try testing.expect(player.flying and player.creative);
    try testing.expectEqual(20, player.health);
    try testing.expectEqual(null, player.inventory.held());
}
