//! Sky and block light, flood-filled across the loaded chunks.
//!
//! Every block stores two levels, 0..15 (`Chunk.light`). Light loses one level per
//! block it travels plus the `lightOpacity` of the block it enters; opaque blocks stop
//! it. Full-strength sky light travels straight down without loss, so open ground is
//! at 15 and shade falls off with distance from the sky.
//!
//! New chunks are seeded with sky light falling from the chunk above (or estimated
//! from the heightmap when that isn't loaded), then exchange light with their loaded
//! neighbors. Workers light whole columns of new chunks this way before they join the
//! world (`initColumn`), so only the exchange is left for the main thread. Edits remove
//! the light around the changed block and flood it back in. Light only spreads through
//! loaded chunks; chunks loaded later pull it in.

const std = @import("std");
const chunk = @import("chunk.zig");
const Chunk = chunk.Chunk;
const BlockId = @import("block.zig").BlockId;
const Terrain = @import("terrain.zig");
const World = @import("world.zig");

const size = chunk.size;

pub const max = 15;

pub const Channel = enum { sky, block };
const channels = [_]Channel{ .sky, .block };

/// The `channel` level of a packed light byte.
pub inline fn level(light: u8, channel: Channel) u4 {
    return @truncate(switch (channel) {
        .sky => light >> 4,
        .block => light,
    });
}

inline fn withLevel(light: u8, channel: Channel, value: u4) u8 {
    return switch (channel) {
        .sky => (light & 0x0f) | @as(u8, value) << 4,
        .block => (light & 0xf0) | value,
    };
}

/// Directions in mesher face order: +X, -X, +Y, -Y, +Z, -Z; `dir ^ 1` is the opposite one.
const directions = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
const down = 3;

/// `BlockId.lightOpacity` and `lightEmission` by block id: these run for every block
/// light touches.
const opacities = blockTable(BlockId.lightOpacity);
const emissions = blockTable(BlockId.lightEmission);

fn blockTable(comptime property: fn (BlockId) u4) [256]u4 {
    @setEvalBranchQuota(10_000);
    var table: [256]u4 = undefined;
    for (&table, 0..) |*v, id| v.* = property(@enumFromInt(id));
    return table;
}

/// The level light at `from` reaches in the next block, `to`, moving in direction `dir`.
pub inline fn spread(from: u4, to: BlockId, channel: Channel, dir: usize) u4 {
    const opacity = opacities[@intFromEnum(to)];
    if (opacity == max) return 0;
    if (channel == .sky and dir == down and from == max and opacity == 0) return max;
    return from -| @max(1, opacity);
}

const Node = struct {
    c: *Chunk,
    i: u16,
};

const Removal = struct {
    node: Node,
    level: u4,
};

/// Work lists, kept between updates to reuse their memory.
pub const Queues = struct {
    add: std.ArrayList(Node) = .empty,
    remove: std.ArrayList(Removal) = .empty,
    /// chunks whose mesh an edit made stale
    touched: std.ArrayList(*Chunk) = .empty,
    /// sky levels of a chunk being seeded
    scratch: chunk.Light = undefined,

    /// Forgets queued work, after an error left some behind.
    pub fn clear(self: *Queues) void {
        self.add.clearRetainingCapacity();
        self.remove.clearRetainingCapacity();
        self.touched.clearRetainingCapacity();
    }

    pub fn deinit(self: *Queues, allocator: std.mem.Allocator) void {
        self.add.deinit(allocator);
        self.remove.deinit(allocator);
        self.touched.deinit(allocator);
    }
};

/// How remeshing caused by light changes is scheduled.
const Mode = enum {
    /// through the per-frame mesh budget (chunk loading)
    streaming,
    /// right away, like the edit that caused it
    edit,
};

/// The chunks light spreads through: every loaded chunk (on the main thread), or a
/// column of new chunks being generated on a worker.
const Space = struct {
    allocator: std.mem.Allocator,
    queues: *Queues,
    /// null for a column
    world: ?*World = null,
    /// top to bottom
    column: []const *Chunk = &.{},

    fn of(world: *World) Space {
        return .{ .allocator = world.allocator, .queues = world.light_queues, .world = world };
    }

    /// The chunk next to `c` in direction `dir`, if there is one.
    fn next(s: Space, c: *const Chunk, dir: usize) ?*Chunk {
        const d = directions[dir];
        if (s.world) |world| return world.chunks.get(c.pos.offset(d[0], d[1], d[2]));
        if (d[1] == 0) return null;
        const k = s.column[0].pos.y - c.pos.y - d[1];
        return if (k >= 0 and k < s.column.len) s.column[@intCast(k)] else null;
    }
};

/// Lights a newly generated chunk `c` (already in `world.chunks`) whose column's
/// heightmap is `map`, and spreads light between it and its loaded neighbors.
pub fn initChunk(world: *World, c: *Chunk, map: *const Terrain.Heightmap) !void {
    const s: Space = .of(world);
    const emitters = try seed(s, c, world.chunks.get(c.pos.offset(0, 1, 0)), map);
    try exchangeFaces(s, c, .sky);
    try propagate(s, .sky);
    if (emitters) try queueEmitters(s, c);
    try exchangeFaces(s, c, .block);
    try propagate(s, .block);
    try finish(world, .streaming);
}

/// Lights a column of new chunks, top to bottom, that aren't in the world yet (on a
/// worker): the light falling in from above and spreading inside the column. Once
/// they are added to the world, `integrateChunk` spreads light to and from the rest.
pub fn initColumn(allocator: std.mem.Allocator, queues: *Queues, column: []const *Chunk, map: *const Terrain.Heightmap) !void {
    const s: Space = .{ .allocator = allocator, .queues = queues, .column = column };
    var emitters = false;
    for (column, 0..) |c, k| {
        if (try seed(s, c, if (k > 0) column[k - 1] else null, map)) emitters = true;
    }
    try propagate(s, .sky);
    if (emitters) {
        for (column) |c| if (c.has_block_light) try queueEmitters(s, c);
    }
    try propagate(s, .block);
}

/// Spreads light between a chunk lit by `initColumn`, just added to the world, and its
/// loaded neighbors (including the chunk above from the same column, which may have
/// been lit further since).
pub fn integrateChunk(world: *World, c: *Chunk) !void {
    const s: Space = .of(world);
    try exchangeFaces(s, c, .sky);
    try propagate(s, .sky);
    try exchangeFaces(s, c, .block);
    try propagate(s, .block);
    try finish(world, .streaming);
}

/// Sets the initial light of a new chunk from the sky light falling in from `above`
/// (or estimated from `map` without it), and queues what spreads sideways inside the
/// chunk. Returns whether it has blocks that give off light, for `queueEmitters`.
fn seed(s: Space, c: *Chunk, above: ?*const Chunk, map: *const Terrain.Heightmap) !bool {
    if (uniformSeed(c, above, map)) |uniform| {
        c.uniform_light = uniform;
        return false;
    }
    const scratch = &s.queues.scratch;
    const emitters = seedSky(c, above, map, scratch);
    // keep uniform light compact
    const first = scratch[0];
    if (std.mem.allEqual(u8, scratch, first)) {
        c.uniform_light = first;
    } else {
        const light = try s.allocator.create(chunk.Light);
        light.* = scratch.*;
        c.light = light;
        // seeding settles each column from top to bottom, so inside the chunk only the
        // sideways spread between columns is left
        try queueSideways(s, c, light);
    }
    c.has_block_light = emitters;
    return emitters;
}

/// Queues the blocks of `c` that give off light, to spread their block light.
fn queueEmitters(s: Space, c: *Chunk) !void {
    for (0..chunk.volume) |i| {
        if (emissions[@intFromEnum(c.getIndex(i))] > 0) try s.queues.add.append(s.allocator, .{ .c = c, .i = @intCast(i) });
    }
}

/// The single light value of a uniform chunk lit evenly (solid rock, open sky), or null.
fn uniformSeed(c: *const Chunk, above: ?*const Chunk, map: *const Terrain.Heightmap) ?u8 {
    if (c.blocks != null) return null;
    if (c.uniform.lightOpacity() == max) return withLevel(c.uniform.lightEmission(), .sky, 0);
    if (c.uniform.lightOpacity() != 0 or c.uniform.lightEmission() != 0) return null;
    // see-through: lit evenly only if full sky light falls in everywhere
    for (0..size) |z| {
        for (0..size) |x| {
            const v = if (above) |a|
                level(a.getLight(chunk.index(x, 0, z)), .sky)
            else
                estimateSky(c.pos.y * size + size, map.heights[z][x]);
            if (v != max) return null;
        }
    }
    return withLevel(0, .sky, max);
}

/// Sky levels of a new chunk from the light falling into it, plus block light of
/// its emitters, written into `out`. Returns whether there are any emitters.
fn seedSky(c: *const Chunk, above: ?*const Chunk, map: *const Terrain.Heightmap, out: *chunk.Light) bool {
    const y0 = c.pos.y * size;
    var emitters = false;
    for (0..size) |z| {
        for (0..size) |x| {
            // level of the block just above the chunk
            var v: u4 = if (above) |a|
                level(a.getLight(chunk.index(x, 0, z)), .sky)
            else
                estimateSky(y0 + size, map.heights[z][x]);
            var y: usize = size;
            while (y > 0) {
                y -= 1;
                const i = chunk.index(x, y, z);
                const block = if (c.blocks) |blocks| blocks[i] else c.uniform;
                v = spread(v, block, .sky, down);
                const emission = emissions[@intFromEnum(block)];
                emitters = emitters or emission > 0;
                out[i] = withLevel(emission, .sky, v);
            }
        }
    }
    return emitters;
}

/// Sky light at height `y` of a generated column with surface height `surface`
/// (trees ignored).
fn estimateSky(y: i32, surface: i32) u4 {
    if (y <= surface) return 0;
    // each block of water below the surface loses one more level
    if (y <= Terrain.sea_level) return @intCast(@max(max - (Terrain.sea_level - y + 1), 0));
    return max;
}

/// Queues the blocks of `c` that can raise the sky light of a neighbor in x or z
/// within the chunk.
fn queueSideways(s: Space, c: *Chunk, light: *const chunk.Light) !void {
    for (0..size) |y| {
        // evenly lit layers (open air, solid rock) have nothing to spread
        const layer = light[y * size * size ..][0 .. size * size];
        if (std.mem.allEqual(u8, layer, layer[0])) continue;
        for (0..size) |z| {
            for (0..size) |x| {
                const i = chunk.index(x, y, z);
                const v: u4 = @intCast(light[i] >> 4);
                if (v <= 1) continue;
                if ((x > 0 and raises(c, light, v, i - 1)) or
                    (x < size - 1 and raises(c, light, v, i + 1)) or
                    (z > 0 and raises(c, light, v, i - size)) or
                    (z < size - 1 and raises(c, light, v, i + size)))
                {
                    try s.queues.add.append(s.allocator, .{ .c = c, .i = @intCast(i) });
                }
            }
        }
    }
}

/// Whether sky light `v` spreading sideways into block `j` brightens it.
inline fn raises(c: *const Chunk, light: *const chunk.Light, v: u4, j: usize) bool {
    const current: u4 = @intCast(light[j] >> 4);
    // cheap test first: nothing to gain unless it is at least two levels darker
    return @as(u5, current) + 1 < v and spread(v, c.getIndex(j), .sky, 0) > current;
}

/// Queues the blocks on either side of each face `c` shares with a loaded neighbor
/// that can brighten the block across.
fn exchangeFaces(s: Space, c: *Chunk, channel: Channel) !void {
    const q = s.queues;
    for (directions, 0..) |d, dir| {
        const n = s.next(c, dir) orelse continue;
        if (channel == .block and !c.has_block_light and !n.has_block_light) continue;
        // between chunks uniform in blocks and light, one pair decides for the whole face
        if (c.blocks == null and c.light == null and n.blocks == null and n.light == null) {
            const a = level(c.uniform_light, channel);
            const b = level(n.uniform_light, channel);
            if (spread(a, n.uniform, channel, dir) <= b and spread(b, c.uniform, channel, dir ^ 1) <= a) continue;
        }
        const axis = axisOf(dir);
        const positive = d[axis] > 0;
        for (0..size) |a| {
            for (0..size) |b| {
                var pa: [3]usize = undefined;
                pa[axis] = if (positive) size - 1 else 0;
                pa[(axis + 1) % 3] = a;
                pa[(axis + 2) % 3] = b;
                var pb = pa;
                pb[axis] = size - 1 - pa[axis];
                const ia = chunk.index(pa[0], pa[1], pa[2]);
                const ib = chunk.index(pb[0], pb[1], pb[2]);
                const va = level(c.getLight(ia), channel);
                const vb = level(n.getLight(ib), channel);
                // light never raises an equally lit block
                if (va == vb) continue;
                if (spread(va, n.getIndex(ib), channel, dir) > vb) {
                    try q.add.append(s.allocator, .{ .c = c, .i = @intCast(ia) });
                }
                if (spread(vb, c.getIndex(ia), channel, dir ^ 1) > va) {
                    try q.add.append(s.allocator, .{ .c = n, .i = @intCast(ib) });
                }
            }
        }
    }
}

/// Updates the light after the block at chunk `c`, index `i` changed to `block`.
pub fn blockChanged(world: *World, c: *Chunk, i: usize, block: BlockId) !void {
    const s: Space = .of(world);
    const q = s.queues;
    const node: Node = .{ .c = c, .i = @intCast(i) };
    for (channels) |channel| {
        // take away whatever light the block had and everything it lit
        const v = get(node, channel);
        if (v > 0) {
            try set(s, node, channel, 0);
            try q.remove.append(s.allocator, .{ .node = node, .level = v });
        }
        try unpropagate(s, channel);

        if (channel == .block and block.lightEmission() > 0) {
            try set(s, node, channel, block.lightEmission());
            try q.add.append(s.allocator, node);
        }
        // let the neighbors light the block again
        for (0..6) |dir| {
            const n = neighbor(s, node, dir) orelse continue;
            if (get(n, channel) > 0) try q.add.append(s.allocator, n);
        }
        try propagate(s, channel);
    }
    try finish(world, .edit);
}

/// Floods light outward from every block in the add queue.
fn propagate(s: Space, channel: Channel) !void {
    const q = s.queues;
    var head: usize = 0;
    while (head < q.add.items.len) : (head += 1) {
        const node = q.add.items[head];
        const v = get(node, channel);
        if (v <= 1) continue;
        for (0..6) |dir| {
            const n = neighbor(s, node, dir) orelse continue;
            const reached = spread(v, n.c.getIndex(n.i), channel, dir);
            if (reached > get(n, channel)) {
                try set(s, n, channel, reached);
                try q.add.append(s.allocator, n);
            }
        }
    }
    q.add.clearRetainingCapacity();
}

/// Darkens everything the blocks in the remove queue lit, and queues the brighter
/// blocks around the dark area so `propagate` can fill it back in.
fn unpropagate(s: Space, channel: Channel) !void {
    const q = s.queues;
    var head: usize = 0;
    while (head < q.remove.items.len) : (head += 1) {
        const r = q.remove.items[head];
        for (0..6) |dir| {
            const n = neighbor(s, r.node, dir) orelse continue;
            const v = get(n, channel);
            if (v == 0) continue;
            const emitter = channel == .block and emissions[@intFromEnum(n.c.getIndex(n.i))] > 0;
            // light the removed block could have given it
            const dependent = v < r.level or (channel == .sky and dir == down and r.level == max and v == max);
            if (dependent and !emitter) {
                try set(s, n, channel, 0);
                try q.remove.append(s.allocator, .{ .node = n, .level = v });
            } else {
                try q.add.append(s.allocator, n);
            }
        }
    }
    q.remove.clearRetainingCapacity();
}

inline fn get(n: Node, channel: Channel) u4 {
    return level(n.c.getLight(n.i), channel);
}

/// Writes a level and remembers the chunk for `finish` (in the world).
fn set(s: Space, n: Node, channel: Channel, value: u4) !void {
    try n.c.setLight(s.allocator, n.i, withLevel(n.c.getLight(n.i), channel, value));
    if (channel == .block and value > 0) n.c.has_block_light = true;
    // a new column has no meshes to update
    if (s.world == null) return;
    if (!n.c.relit) {
        n.c.relit = true;
        try s.queues.touched.append(s.allocator, n.c);
    }
    const p = coords(n.i);
    for (p, 0..) |v, axis| {
        if (v == size - 1) n.c.relit_sides |= @as(u6, 1) << @intCast(axis * 2);
        if (v == 0) n.c.relit_sides |= @as(u6, 1) << @intCast(axis * 2 + 1);
    }
}

/// Schedules remeshing of every chunk whose light changed, and of the neighbors on the
/// sides where it changed on the border (their meshes include a one-block border of it).
fn finish(world: *World, mode: Mode) !void {
    const q = world.light_queues;
    for (q.touched.items) |c| {
        try remesh(world, c, mode);
        if (c.relit_sides != 0) {
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dz: i32 = -1;
                while (dz <= 1) : (dz += 1) {
                    var dx: i32 = -1;
                    while (dx <= 1) : (dx += 1) {
                        if (dx == 0 and dy == 0 and dz == 0) continue;
                        // an edge or corner neighbor only when each of its sides changed (approximately)
                        if (!sideChanged(c.relit_sides, 0, dx) or !sideChanged(c.relit_sides, 1, dy) or !sideChanged(c.relit_sides, 2, dz)) continue;
                        const n = world.chunks.get(c.pos.offset(dx, dy, dz)) orelse continue;
                        try remesh(world, n, mode);
                    }
                }
            }
        }
        c.relit = false;
        c.relit_sides = 0;
    }
    q.touched.clearRetainingCapacity();
}

/// Whether the border towards offset `d` (-1, 0 or 1) on `axis` changed; true for 0.
fn sideChanged(sides: u6, axis: usize, d: i32) bool {
    if (d == 0) return true;
    const side = axis * 2 + @intFromBool(d < 0);
    return sides & (@as(u6, 1) << @intCast(side)) != 0;
}

/// Marks the chunk's mesh as stale.
fn remesh(world: *World, c: *Chunk, mode: Mode) !void {
    switch (mode) {
        .streaming => {
            if (c.state == .generated) return;
            c.state = .generated;
        },
        .edit => {
            // never meshed: streaming will get to it
            if (c.state == .generated and c.mesh == null and c.translucent_mesh == null) return;
            c.state = .generated;
            try world.dirty.append(world.allocator, c.pos);
        },
    }
    world.settled = false;
}

/// The block next to `n` in direction `dir`, if its chunk is loaded.
fn neighbor(s: Space, n: Node, dir: usize) ?Node {
    const p = step(coords(n.i), dir);
    const axis = axisOf(dir);
    if (p[axis] >= 0 and p[axis] < size) return .{ .c = n.c, .i = @intCast(index(p)) };
    const c = s.next(n.c, dir) orelse return null;
    var wrapped = p;
    wrapped[axis] = @mod(p[axis], size);
    return .{ .c = c, .i = @intCast(index(wrapped)) };
}

fn axisOf(dir: usize) usize {
    return dir / 2;
}

/// `p` moved one block in direction `dir`.
fn step(p: [3]i32, dir: usize) [3]i32 {
    const d = directions[dir];
    return .{ p[0] + d[0], p[1] + d[1], p[2] + d[2] };
}

fn coords(i: usize) [3]i32 {
    return .{ @intCast(i % size), @intCast(i / (size * size)), @intCast(i / size % size) };
}

fn index(p: [3]i32) usize {
    return chunk.index(@intCast(p[0]), @intCast(p[1]), @intCast(p[2]));
}
