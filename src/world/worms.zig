//! Cave tunnels carved by "worms": random walks that wind up and down through the
//! ground, widening in the middle and branching once, so tunnels cross each other and
//! join up into networks. Some start at the surface and lead down into them.
//!
//! Each chunk column may start cave systems, chosen from (seed, column) alone, so a
//! column's tunnels are the same whichever chunk generates them. A system's tunnels
//! never wander farther than `reach` blocks from the column it starts in.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const chunk = @import("chunk.zig");

/// One step of a tunnel: an ellipsoid, round across and `ry` tall.
pub const Sphere = struct {
    x: f32,
    y: f32,
    z: f32,
    r: f32,
    ry: f32,

    /// Whether the block (x, y, z) has its center inside.
    pub fn contains(s: Sphere, x: i32, y: i32, z: i32) bool {
        const dx = (@as(f32, @floatFromInt(x)) + 0.5 - s.x) / s.r;
        const dy = (@as(f32, @floatFromInt(y)) + 0.5 - s.y) / s.ry;
        const dz = (@as(f32, @floatFromInt(z)) + 0.5 - s.z) / s.r;
        return dx * dx + dy * dy + dz * dz < 1;
    }

    /// Whether the sphere's bounding box overlaps the blocks [lo, hi] (inclusive).
    pub fn overlaps(s: Sphere, lo: [3]i32, hi: [3]i32) bool {
        return s.x + s.r > @as(f32, @floatFromInt(lo[0])) and s.x - s.r < @as(f32, @floatFromInt(hi[0] + 1)) and
            s.y + s.ry > @as(f32, @floatFromInt(lo[1])) and s.y - s.ry < @as(f32, @floatFromInt(hi[1] + 1)) and
            s.z + s.r > @as(f32, @floatFromInt(lo[2])) and s.z - s.r < @as(f32, @floatFromInt(hi[2] + 1));
    }
};

/// Systems start between these heights, more of them deeper down.
pub const start_min = -54;
pub const start_max = 48;

/// Steps of a tunnel and of the two it branches into, together.
const max_steps = 160;
const max_radius = 8;
/// How far (in blocks) a system's tunnels can reach from its column.
pub const reach = max_steps + max_radius;

/// Chance that a column starts one cave system, and two.
const one_system = 0.6;
const two_systems = 0.2;
/// Chance that a column tries to start a tunnel down from the surface; it does where
/// the terrain allows an entrance.
const entrance_tries = 0.6;

/// Collects every tunnel sphere whose box overlaps the blocks [x0, x1] × [z0, z1] (any
/// height) into `out`, in a fixed order. Returns how many there are; ones past the end
/// of `out` are dropped. `terrain` has a `seed`, a `worms: ?*Cache` to keep the
/// systems in, and an `entranceHeight(x, z) ?i32` method: the surface height where a
/// tunnel may break through it, or null.
pub fn collect(terrain: anytype, x0: i32, z0: i32, x1: i32, z1: i32, out: []Sphere) usize {
    var sink: Sink = .{ .lo = .{ x0, std.math.minInt(i32) / 2, z0 }, .hi = .{ x1, std.math.maxInt(i32) / 2, z1 }, .out = out };
    var cz = @divFloor(z0 - reach, chunk.size);
    while (cz <= @divFloor(z1 + reach, chunk.size)) : (cz += 1) {
        var cx = @divFloor(x0 - reach, chunk.size);
        while (cx <= @divFloor(x1 + reach, chunk.size)) : (cx += 1) {
            if (terrain.worms) |cache| {
                if (cache.collect(terrain, .{ cx, cz }, &sink)) continue;
            }
            system(terrain, cx, cz, &sink);
        }
    }
    return sink.count;
}

/// The spheres of the systems of recently used columns, shared by the threads that
/// generate terrain, so each column's tunnels are walked once instead of by every
/// column they may reach.
pub const Cache = struct {
    allocator: Allocator,
    io: Io,
    lock: Io.RwLock = .init,
    /// the seed the systems are for; other seeds aren't cached
    seed: u64,
    /// every sphere of the column's systems, keyed by column
    systems: std.AutoHashMapUnmanaged([2]i32, []Sphere) = .empty,

    pub fn init(allocator: Allocator, io: Io, seed: u64) Cache {
        return .{ .allocator = allocator, .io = io, .seed = seed };
    }

    pub fn deinit(self: *Cache) void {
        self.clear(self.seed);
        self.systems.deinit(self.allocator);
    }

    /// Forgets every column, to cache the systems of `seed` from now on.
    pub fn clear(self: *Cache, seed: u64) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.seed = seed;
        var it = self.systems.valueIterator();
        while (it.next()) |spheres| self.allocator.free(spheres.*);
        self.systems.clearRetainingCapacity();
    }

    /// Forgets the columns more than `radius` columns from `center` (in x or z).
    pub fn retain(self: *Cache, center: [2]i32, radius: i32) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        var far: std.ArrayList([2]i32) = .empty;
        defer far.deinit(self.allocator);
        var it = self.systems.keyIterator();
        while (it.next()) |c| {
            if (@abs(c[0] - center[0]) <= radius and @abs(c[1] - center[1]) <= radius) continue;
            // out of memory: the rest go next time
            far.append(self.allocator, c.*) catch break;
        }
        for (far.items) |c| self.allocator.free(self.systems.fetchRemove(c).?.value);
    }

    /// Adds the spheres of `column`'s systems to `sink`, walking them first if they
    /// aren't cached yet. False if they couldn't be cached (out of memory).
    fn collect(self: *Cache, terrain: anytype, column: [2]i32, sink: *Sink) bool {
        self.lock.lockSharedUncancelable(self.io);
        // a generator still busy with the previous seed
        if (self.seed != terrain.seed) {
            self.lock.unlockShared(self.io);
            return false;
        }
        if (self.systems.get(column)) |spheres| {
            defer self.lock.unlockShared(self.io);
            for (spheres) |s| sink.add(s);
            return true;
        }
        self.lock.unlockShared(self.io);

        // walk them without holding the lock
        var list: std.ArrayList(Sphere) = .empty;
        var all: Sink = .{ .lo = undefined, .hi = undefined, .out = &.{}, .list = &list, .allocator = self.allocator };
        system(terrain, column[0], column[1], &all);
        if (all.failed) {
            list.deinit(self.allocator);
            return false;
        }
        const spheres = list.toOwnedSlice(self.allocator) catch {
            list.deinit(self.allocator);
            return false;
        };

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.seed != terrain.seed) {
            self.allocator.free(spheres);
            return false;
        }
        const entry = self.systems.getOrPut(self.allocator, column) catch {
            self.allocator.free(spheres);
            return false;
        };
        if (entry.found_existing) {
            // another thread got there first
            self.allocator.free(spheres);
        } else entry.value_ptr.* = spheres;
        for (entry.value_ptr.*) |s| sink.add(s);
        return true;
    }
};

const Sink = struct {
    lo: [3]i32,
    hi: [3]i32,
    out: []Sphere,
    count: usize = 0,
    /// if set, takes every sphere instead
    list: ?*std.ArrayList(Sphere) = null,
    allocator: Allocator = undefined,
    failed: bool = false,

    fn add(self: *Sink, s: Sphere) void {
        if (self.list) |list| {
            list.append(self.allocator, s) catch {
                self.failed = true;
            };
            return;
        }
        if (!s.overlaps(self.lo, self.hi)) return;
        if (self.count < self.out.len) self.out[self.count] = s;
        self.count += 1;
    }
};

/// The cave systems starting in chunk column (cx, cz).
fn system(terrain: anytype, cx: i32, cz: i32, sink: *Sink) void {
    var prng = std.Random.DefaultPrng.init(hash(terrain.seed, cx, cz));
    const rng = prng.random();
    const column_x: f32 = @floatFromInt(cx * chunk.size);
    const column_z: f32 = @floatFromInt(cz * chunk.size);

    const roll = rng.float(f32);
    const systems: u32 = if (roll < two_systems) 2 else if (roll < one_system) 1 else 0;
    for (0..systems) |_| {
        const x = column_x + rng.float(f32) * chunk.size;
        const z = column_z + rng.float(f32) * chunk.size;
        // biased deep: a random height below a random height
        const span: u32 = start_max - start_min;
        const y = @as(f32, @floatFromInt(start_min + @as(i32, @intCast(rng.uintLessThan(u32, rng.uintLessThan(u32, span) + 1))))) + 0.5;
        if (rng.float(f32) < 0.3) {
            // a room for the tunnels to leave from
            const r = 3.5 + rng.float(f32) * 3.5;
            sink.add(.{ .x = x, .y = y, .z = z, .r = r, .ry = r * 0.6 });
        }
        const tunnels = 2 + rng.uintLessThan(u32, 3);
        for (0..tunnels) |_| {
            const yaw = rng.float(f32) * std.math.tau;
            const pitch = (rng.float(f32) - 0.5) * 0.8;
            const width = 0.8 + rng.float(f32) * 2.2;
            // some tunnels keep their slope longer, and climb or drop steeply
            const keep: f32 = if (rng.uintLessThan(u32, 3) == 0) 0.94 else 0.7;
            tunnel(rng, sink, .{ x, y, z }, yaw, pitch, keep, width, 70 + rng.uintLessThan(u32, 43), max_steps);
        }
    }

    if (rng.float(f32) < entrance_tries) {
        const x = column_x + rng.float(f32) * chunk.size;
        const z = column_z + rng.float(f32) * chunk.size;
        const yaw = rng.float(f32) * std.math.tau;
        const width = 0.8 + rng.float(f32) * 1.2;
        const steps = 90 + rng.uintLessThan(u32, 23);
        if (terrain.entranceHeight(@intFromFloat(@floor(x)), @intFromFloat(@floor(z)))) |surface| {
            // starts just under the surface and heads steeply down
            const y = @as(f32, @floatFromInt(surface)) + 0.5;
            tunnel(rng, sink, .{ x, y, z }, yaw, -0.9, 0.97, width, steps, max_steps);
        }
    }
}

/// Walks one tunnel of `steps` steps from `start`, branching once if `budget` (steps
/// left for it and its branches) allows. `keep` is how much of its slope it keeps from
/// one step to the next.
fn tunnel(rng: std.Random, sink: *Sink, start: [3]f32, yaw0: f32, pitch0: f32, keep: f32, width: f32, steps: u32, budget: u32) void {
    var x, var y, var z = start;
    var yaw = yaw0;
    var pitch = pitch0;
    var yaw_v: f32 = 0;
    var pitch_v: f32 = 0;
    const can_branch = budget >= steps + 40;
    const branch_at = steps / 4 + rng.uintLessThan(u32, steps / 2);
    var i: u32 = 0;
    while (i < steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const r = 1.5 + width * @sin(t * std.math.pi);
        sink.add(.{ .x = x, .y = y, .z = z, .r = r, .ry = r * 0.8 });

        const flat = @cos(pitch);
        x += @cos(yaw) * flat;
        y += @sin(pitch);
        z += @sin(yaw) * flat;
        pitch *= keep;
        pitch += pitch_v * 0.1;
        yaw += yaw_v * 0.1;
        pitch_v *= 0.9;
        yaw_v *= 0.75;
        pitch_v += (rng.float(f32) - rng.float(f32)) * rng.float(f32) * 2;
        yaw_v += (rng.float(f32) - rng.float(f32)) * rng.float(f32) * 4;

        if (can_branch and i == branch_at) {
            const left = @min(budget - i - 1, 70 + rng.uintLessThan(u32, 43));
            const child_width = width * (0.6 + rng.float(f32) * 0.5);
            tunnel(rng, sink, .{ x, y, z }, yaw - std.math.pi / 2.0, pitch / 3, keep, child_width, left, 0);
            tunnel(rng, sink, .{ x, y, z }, yaw + std.math.pi / 2.0, pitch / 3, keep, child_width, left, 0);
            return;
        }
    }
}

fn hash(seed: u64, x: i32, z: i32) u64 {
    var h: u64 = seed ^ 0x6a09e667f3bcc909;
    h ^= @as(u64, @bitCast(@as(i64, x))) *% 0xbf58476d1ce4e5b9;
    h = std.math.rotl(u64, h, 31);
    h ^= @as(u64, @bitCast(@as(i64, z))) *% 0x94d049bb133111eb;
    h ^= h >> 30;
    h *%= 0xbf58476d1ce4e5b9;
    h ^= h >> 27;
    h *%= 0x94d049bb133111eb;
    h ^= h >> 31;
    return h;
}

/// Flat ground at y = 40 with an entrance everywhere.
const TestTerrain = struct {
    seed: u64,
    worms: ?*Cache = null,

    fn entranceHeight(_: TestTerrain, _: i32, _: i32) ?i32 {
        return 40;
    }
};

test "tunnels stay within reach of their column" {
    var out: [8192]Sphere = undefined;
    const far = std.math.maxInt(i32) / 2;
    var cz: i32 = -3;
    while (cz <= 3) : (cz += 1) {
        var cx: i32 = -3;
        while (cx <= 3) : (cx += 1) {
            var sink: Sink = .{ .lo = .{ -far, -far, -far }, .hi = .{ far, far, far }, .out = &out };
            system(TestTerrain{ .seed = 42 }, cx, cz, &sink);
            try std.testing.expect(sink.count <= out.len);
            const x0: f32 = @floatFromInt(cx * chunk.size);
            const z0: f32 = @floatFromInt(cz * chunk.size);
            for (out[0..sink.count]) |s| {
                try std.testing.expect(s.x + s.r > x0 - reach and s.x - s.r < x0 + chunk.size + reach);
                try std.testing.expect(s.z + s.r > z0 - reach and s.z - s.r < z0 + chunk.size + reach);
            }
        }
    }
}

test "every step of a tunnel overlaps the one before" {
    var out: [1024]Sphere = undefined;
    var sink: Sink = .{ .lo = .{ -1 << 20, -1 << 20, -1 << 20 }, .hi = .{ 1 << 20, 1 << 20, 1 << 20 }, .out = &out };
    var prng = std.Random.DefaultPrng.init(5);
    tunnel(prng.random(), &sink, .{ 0, 0, 0 }, 0.3, 0.2, 0.94, 2, 100, 100);
    try std.testing.expectEqual(@as(usize, 100), sink.count);
    for (out[1..sink.count], out[0 .. sink.count - 1]) |s, prev| {
        const dx = s.x - prev.x;
        const dy = s.y - prev.y;
        const dz = s.z - prev.z;
        try std.testing.expect(@sqrt(dx * dx + dy * dy + dz * dz) < @min(s.ry, prev.ry) + 0.01);
    }
}

test "cached tunnels are the same as walked ones" {
    var cache: Cache = .init(std.testing.allocator, std.testing.io, 42);
    defer cache.deinit();
    var direct: [4096]Sphere = undefined;
    var cached: [4096]Sphere = undefined;
    const n = collect(TestTerrain{ .seed = 42 }, 0, 0, 31, 31, &direct);
    try std.testing.expect(n > 0 and n <= direct.len);
    // twice: walking them into the cache, then from it
    for (0..2) |_| {
        const m = collect(TestTerrain{ .seed = 42, .worms = &cache }, 0, 0, 31, 31, &cached);
        try std.testing.expectEqualSlices(Sphere, direct[0..n], cached[0..m]);
    }
    try std.testing.expect(cache.systems.count() > 0);

    // a generator of another seed doesn't use it
    const other = collect(TestTerrain{ .seed = 7, .worms = &cache }, 0, 0, 31, 31, &cached);
    try std.testing.expectEqual(other, collect(TestTerrain{ .seed = 7 }, 0, 0, 31, 31, &direct));

    cache.retain(.{ 0, 0 }, 1);
    try std.testing.expect(cache.systems.count() <= 9);
    cache.clear(7);
    try std.testing.expectEqual(0, cache.systems.count());
}
