//! The set of loaded chunks around the camera: generates, meshes and unloads
//! them with a per-frame budget, and draws the visible ones.

const std = @import("std");
const Allocator = std.mem.Allocator;

const chunk = @import("chunk.zig");
const Chunk = chunk.Chunk;
const ChunkPos = chunk.ChunkPos;
const BlockId = @import("block.zig").BlockId;
const mesher = @import("mesher.zig");
const light = @import("light.zig");
const Pool = @import("workers.zig");
const Save = @import("save.zig");
const Terrain = @import("terrain.zig");
const math = @import("../math.zig");
const MeshArena = @import("../gfx/mesh_arena.zig");
const VoxelPipeline = @import("../gfx/voxel_pipeline.zig");
const vk = @import("../gfx/vulkan_context.zig").vk;

const log = std.log.scoped(.world);

const Self = @This();

pub const Config = struct {
    /// horizontal radius in chunks (square)
    render_distance: i32,
    /// vertical chunk range that is meshed and drawn
    min_y: i32,
    max_y: i32,
    /// chunks added to the world per frame (whole columns)
    gen_budget: u32,
    /// mesh jobs started per frame
    mesh_budget: u32,
};

/// A set of chunk columns (x, z).
pub const ColumnSet = std.AutoHashMapUnmanaged([2]i32, void);

pub const Stats = struct {
    loaded: u32 = 0,
    /// chunks with a non-empty mesh
    meshed: u32 = 0,
    drawn: u32 = 0,
    drawn_vertices: u64 = 0,
    /// chunks within view distance that are still waiting for a mesh
    pending: u32 = 0,
    generated_this_frame: u32 = 0,
    meshed_this_frame: u32 = 0,
    arena_full: bool = false,
    workers: u32 = 0,
    /// columns being generated (or waiting to be added) and chunks being meshed
    gen_jobs: u32 = 0,
    mesh_jobs: u32 = 0,

    // main thread time spent this frame
    update_ms: f32 = 0,
    gen_ms: f32 = 0,
    mesh_ms: f32 = 0,
    draw_ms: f32 = 0,
    // totals since the last regenerate, for per-chunk averages; including the time
    // spent on the workers
    gen_total: u64 = 0,
    gen_total_ns: u64 = 0,
    mesh_total: u64 = 0,
    mesh_total_ns: u64 = 0,
    /// mesh passes skipped because the chunk was buried
    mesh_skipped: u64 = 0,
};

allocator: Allocator,
io: std.Io,
terrain: Terrain,
/// edited chunks, saved when they unload and on `saveAll`
save: Save,
/// where `openSave` keeps the worlds; null until then (saved in memory only)
saves_dir: ?std.Io.Dir = null,
chunks: std.AutoHashMapUnmanaged(ChunkPos, *Chunk) = .empty,
/// heightmaps of loaded chunk columns, keyed by column (x, z)
heightmaps: std.AutoHashMapUnmanaged([2]i32, *Terrain.Heightmap) = .empty,
/// column offsets within `offsets_radius + 2`, nearest first
offsets: std.ArrayList([2]i32) = .empty,
offsets_radius: i32 = -1,
mesh_options: mesher.Options = .{},
light_queues: *light.Queues,
/// worker threads generating and meshing chunks
pool: *Pool,
/// for jobs run on the main thread (without workers, or while waiting for edits)
main_context: Pool.Context,
/// every job ever allocated, and the ones not in use
gen_jobs: std.ArrayList(*GenJob) = .empty,
mesh_jobs: std.ArrayList(*MeshJob) = .empty,
free_gen_jobs: std.ArrayList(*GenJob) = .empty,
free_mesh_jobs: std.ArrayList(*MeshJob) = .empty,
finished_jobs: std.ArrayList(*Pool.Job) = .empty,
/// generated columns waiting to be added to the world, oldest first
ready_columns: std.ArrayList(*GenJob) = .empty,
/// columns being generated or waiting in `ready_columns`
columns_in_flight: ColumnSet = .empty,
gen_in_flight: u32 = 0,
mesh_in_flight: u32 = 0,
/// identifies mesh jobs (`Chunk.mesh_job`); 0 is none
next_job_id: u64 = 1,
/// bumped by `regenerate`, so columns generated before it are dropped
epoch: u32 = 0,
/// translucent chunk draws of the frame, sorted back to front
translucent_draws: std.ArrayList(TranslucentDraw) = .empty,
scratch_keys: std.ArrayList(ChunkPos) = .empty,
scratch_columns: std.ArrayList([2]i32) = .empty,
/// chunks whose blocks were edited (or that border an edit) and need a new mesh;
/// meshed at the start of the next update regardless of the mesh budget
dirty: std.ArrayList(ChunkPos) = .empty,
/// center and config of the previous update; unloading only runs when they change
last_center: ?ChunkPos = null,
last_config: ?Config = null,
/// every chunk in range is generated and meshed, so updates can be skipped
settled: bool = false,
stats: Stats = .{},

const TranslucentDraw = struct {
    distance: f32,
    origin: math.Vec3,
    range: chunk.MeshRange,
};

/// Generates the chunks of a column, top down, and lights them (`light.initColumn`).
const GenJob = struct {
    job: Pool.Job = .{ .run = run },
    terrain: Terrain,
    epoch: u32,
    column: [2]i32,
    /// chunk y range
    top: i32,
    bottom: i32,
    map: *Terrain.Heightmap,
    /// saved blocks to use instead of the terrain's, top to bottom like `chunks`
    saved: std.ArrayList(?*chunk.Blocks) = .empty,
    /// top to bottom; owned by the job until added to the world
    chunks: std.ArrayList(*Chunk) = .empty,
    err: ?anyerror = null,
    ns: u64 = 0,

    fn run(job: *Pool.Job, ctx: *Pool.Context) void {
        const self: *GenJob = @fieldParentPtr("job", job);
        const start: std.Io.Timestamp = .now(ctx.io, .awake);
        self.generate(ctx) catch |err| {
            self.err = err;
            ctx.light_queues.clear();
        };
        self.ns = @intCast(@max(start.untilNow(ctx.io, .awake).nanoseconds, 0));
    }

    fn generate(self: *GenJob, ctx: *Pool.Context) !void {
        self.terrain.heightmap(self.column[0], self.column[1], self.map);
        var y = self.top;
        while (y >= self.bottom) : (y -= 1) {
            const saved = &self.saved.items[@intCast(self.top - y)];
            defer saved.* = null;
            const c = try buildChunk(ctx.allocator, self.terrain, .{ .x = self.column[0], .y = y, .z = self.column[1] }, self.map, saved.*);
            self.chunks.append(ctx.allocator, c) catch |err| {
                freeChunk(ctx.allocator, c);
                return err;
            };
        }
        try light.initColumn(ctx.allocator, ctx.light_queues, self.chunks.items, self.map);
    }

    fn freeChunks(self: *GenJob, allocator: Allocator) void {
        for (self.chunks.items) |c| freeChunk(allocator, c);
        self.chunks.clearRetainingCapacity();
        for (self.saved.items) |blocks| if (blocks) |b| allocator.destroy(b);
        self.saved.clearRetainingCapacity();
    }
};

/// Meshes a copy of a chunk and its border (`fillPadded`).
const MeshJob = struct {
    job: Pool.Job = .{ .run = run },
    pos: ChunkPos = undefined,
    /// matches `Chunk.mesh_job` while this is the chunk's latest mesh job
    id: u64 = 0,
    options: mesher.Options = .{},
    padded: mesher.Padded = undefined,
    padded_light: mesher.PaddedLight = undefined,
    out: mesher.Output = .{},
    err: ?anyerror = null,
    ns: u64 = 0,

    fn run(job: *Pool.Job, ctx: *Pool.Context) void {
        const self: *MeshJob = @fieldParentPtr("job", job);
        const start: std.Io.Timestamp = .now(ctx.io, .awake);
        self.out.clear();
        mesher.meshChunk(ctx.allocator, &self.padded, &self.padded_light, self.options, &self.out) catch |err| {
            self.err = err;
        };
        self.ns = @intCast(@max(start.untilNow(ctx.io, .awake).nanoseconds, 0));
    }
};

/// Jobs in flight per worker; enough to keep them busy between frames.
const gen_jobs_per_worker = 2;
const mesh_jobs_per_worker = 4;

/// A world without workers, so chunks are generated and meshed on the main thread
/// until `startWorkers`.
pub fn init(allocator: Allocator, io: std.Io, seed: u64) !Self {
    const light_queues = try allocator.create(light.Queues);
    light_queues.* = .{};
    errdefer allocator.destroy(light_queues);
    const pool = try allocator.create(Pool);
    pool.* = .{ .io = io, .allocator = allocator };
    errdefer allocator.destroy(pool);
    return .{
        .allocator = allocator,
        .io = io,
        .terrain = .{ .seed = seed },
        .save = .memory(io, allocator),
        .light_queues = light_queues,
        .pool = pool,
        .main_context = try .create(allocator, io),
    };
}

pub const defaultWorkerCount = Pool.defaultWorkerCount;

/// Saves the world in `saves` from now on, in the folder of its seed, and loads what
/// was saved there. Expects no chunks to be loaded yet.
pub fn openSave(self: *Self, saves: std.Io.Dir) !void {
    const save: Save = try .open(self.io, self.allocator, saves, self.terrain.seed);
    self.save.deinit();
    self.save = save;
    self.saves_dir = saves;
}

/// Writes every edited chunk to the save.
pub fn saveAll(self: *Self) !void {
    var it = self.chunks.valueIterator();
    while (it.next()) |entry| {
        const c = entry.*;
        if (!c.modified) continue;
        try self.save.store(c.pos, c.blocks, c.uniform);
        c.modified = false;
    }
    try self.save.flush();
}

/// The player as saved with the world, if it was.
pub fn savedPlayer(self: *Self) ?Save.Player {
    return self.save.readPlayer();
}

pub fn savePlayer(self: *Self, player: Save.Player) !void {
    try self.save.writePlayer(player);
}

pub fn startWorkers(self: *Self, count: usize) void {
    self.pool.start(count);
    self.stats.workers = @intCast(self.pool.workers);
}

pub fn deinit(self: *Self) void {
    // stop the workers before freeing what they work on
    self.pool.deinit();
    self.allocator.destroy(self.pool);
    self.main_context.destroy();
    for (self.gen_jobs.items) |job| {
        job.freeChunks(self.allocator);
        job.chunks.deinit(self.allocator);
        job.saved.deinit(self.allocator);
        self.allocator.destroy(job.map);
        self.allocator.destroy(job);
    }
    for (self.mesh_jobs.items) |job| {
        job.out.deinit(self.allocator);
        self.allocator.destroy(job);
    }
    self.gen_jobs.deinit(self.allocator);
    self.mesh_jobs.deinit(self.allocator);
    self.free_gen_jobs.deinit(self.allocator);
    self.free_mesh_jobs.deinit(self.allocator);
    self.finished_jobs.deinit(self.allocator);
    self.ready_columns.deinit(self.allocator);
    self.columns_in_flight.deinit(self.allocator);

    var it = self.chunks.valueIterator();
    while (it.next()) |c| self.destroyChunk(c.*);
    self.chunks.deinit(self.allocator);
    self.clearHeightmaps();
    self.heightmaps.deinit(self.allocator);
    self.scratch_columns.deinit(self.allocator);
    self.offsets.deinit(self.allocator);
    self.translucent_draws.deinit(self.allocator);
    self.scratch_keys.deinit(self.allocator);
    self.dirty.deinit(self.allocator);
    self.light_queues.deinit(self.allocator);
    self.allocator.destroy(self.light_queues);
    self.save.deinit();
}

/// Switches how leaves are meshed; loaded chunks are remeshed over the next frames.
pub fn setFastLeaves(self: *Self, fast: bool) void {
    if (self.mesh_options.fast_leaves == fast) return;
    self.mesh_options.fast_leaves = fast;
    var it = self.chunks.valueIterator();
    while (it.next()) |c| {
        if (c.*.state != .generated and c.*.blocks != null) c.*.state = .generated;
    }
    self.settled = false;
}

/// Saves the edits, then drops every chunk to generate the world of `seed` (and load
/// its edits); their mesh ranges are freed as of `frame`.
pub fn regenerate(self: *Self, arena: *MeshArena, seed: u64, frame: u64) !void {
    try self.saveAll();
    if (seed != self.terrain.seed) {
        const save: Save = if (self.saves_dir) |saves| try .open(self.io, self.allocator, saves, seed) else .memory(self.io, self.allocator);
        self.save.deinit();
        self.save = save;
    }
    // columns in flight finish for nothing; mesh jobs find their chunk gone
    self.epoch +%= 1;
    for (self.ready_columns.items) |job| self.releaseGenJob(job);
    self.ready_columns.clearRetainingCapacity();
    self.columns_in_flight.clearRetainingCapacity();
    var it = self.chunks.valueIterator();
    while (it.next()) |c| {
        try freeMeshes(arena, c.*, frame);
        self.destroyChunk(c.*);
    }
    self.chunks.clearRetainingCapacity();
    self.dirty.clearRetainingCapacity();
    self.clearHeightmaps();
    self.terrain = .{ .seed = seed };
    self.stats = .{ .workers = self.stats.workers };
    self.settled = false;
}

/// The block at world position (x, y, z), or null when its chunk isn't loaded.
pub fn getBlock(self: *const Self, x: i32, y: i32, z: i32) ?BlockId {
    const c = self.chunks.get(ChunkPos.fromBlock(x, y, z)) orelse return null;
    const l = local(x, y, z);
    return c.get(l[0], l[1], l[2]);
}

/// Packed light (see light.zig) at world position (x, y, z), or null when its chunk isn't loaded.
pub fn getLight(self: *const Self, x: i32, y: i32, z: i32) ?u8 {
    const c = self.chunks.get(ChunkPos.fromBlock(x, y, z)) orelse return null;
    const l = local(x, y, z);
    return c.getLight(chunk.index(l[0], l[1], l[2]));
}

/// Whether the block blocks movement. Falls back to the generated terrain where no
/// chunk is loaded, so the edge of the loaded area is neither a wall nor a pit.
pub fn isSolid(self: *const Self, x: i32, y: i32, z: i32) bool {
    return self.blockOrTerrain(x, y, z).isSolid();
}

pub fn isWater(self: *const Self, x: i32, y: i32, z: i32) bool {
    return self.blockOrTerrain(x, y, z) == .water;
}

fn blockOrTerrain(self: *const Self, x: i32, y: i32, z: i32) BlockId {
    return self.getBlock(x, y, z) orelse self.terrain.block(x, y, z);
}

/// Changes one block and queues remeshing of its chunk and of every neighbor whose
/// one-block border (faces + AO) contains it. Does nothing if the chunk isn't loaded.
pub fn setBlock(self: *Self, x: i32, y: i32, z: i32, block: BlockId) !void {
    const pos = ChunkPos.fromBlock(x, y, z);
    const c = self.chunks.get(pos) orelse return;
    const l = local(x, y, z);
    if (c.get(l[0], l[1], l[2]) == block) return;
    try c.set(self.allocator, l[0], l[1], l[2], block);
    c.modified = true;
    try light.blockChanged(self, c, chunk.index(l[0], l[1], l[2]), block);

    // per axis: this chunk, plus the neighbor on the side the block touches
    var ranges: [3][2]i32 = undefined;
    for (l, &ranges) |v, *range| {
        range.* = .{ if (v == 0) -1 else 0, if (v == chunk.size - 1) 1 else 0 };
    }
    var dy = ranges[1][0];
    while (dy <= ranges[1][1]) : (dy += 1) {
        var dz = ranges[2][0];
        while (dz <= ranges[2][1]) : (dz += 1) {
            var dx = ranges[0][0];
            while (dx <= ranges[0][1]) : (dx += 1) {
                const n_pos = pos.offset(dx, dy, dz);
                const n = self.chunks.get(n_pos) orelse continue;
                n.state = .generated;
                try self.dirty.append(self.allocator, n_pos);
            }
        }
    }
    self.settled = false;
}

/// Chunk-local coordinates of a world block.
fn local(x: i32, y: i32, z: i32) [3]usize {
    return .{ @intCast(@mod(x, chunk.size)), @intCast(@mod(y, chunk.size)), @intCast(@mod(z, chunk.size)) };
}

pub fn update(self: *Self, arena: *MeshArena, camera_pos: @Vector(3, f64), config: Config, frame: u64) !void {
    const start = self.now();
    var gen_ns: u64 = 0;
    var mesh_ns: u64 = 0;
    defer {
        self.stats.gen_ms = toMs(gen_ns);
        self.stats.mesh_ms = toMs(mesh_ns);
        self.stats.update_ms = toMs(self.since(start));
    }

    const center = ChunkPos.fromWorld(camera_pos);
    const r = @max(config.render_distance, 0);
    if (!std.meta.eql(self.last_center, center) or !std.meta.eql(self.last_config, config)) {
        if (r != self.offsets_radius) try self.buildOffsets(r);
        try self.unloadFar(arena, center, r, config, frame);
        self.last_center = center;
        self.last_config = config;
        self.settled = false;
    }
    self.stats.loaded = self.chunks.count();
    self.stats.generated_this_frame = 0;
    self.stats.meshed_this_frame = 0;

    // finished jobs
    {
        const t = self.now();
        try self.collect(arena, frame);
        mesh_ns += self.since(t);
    }

    // edits first and unbudgeted, waited for so they show up this frame
    if (self.dirty.items.len > 0) {
        const t = self.now();
        var i: usize = 0;
        while (i < self.dirty.items.len) {
            const pos = self.dirty.items[i];
            const in_range = @abs(pos.x - center.x) <= r and @abs(pos.z - center.z) <= r and
                pos.y >= config.min_y and pos.y <= config.max_y;
            // out of range: streaming meshes it when it comes back into view
            const c = (if (in_range) self.chunks.get(pos) else null) orelse {
                _ = self.dirty.swapRemove(i);
                continue;
            };
            if (!self.neighborsLoaded(pos)) {
                i += 1;
                continue;
            }
            if (c.state == .generated) try self.submitMesh(arena, c, frame, true);
            _ = self.dirty.swapRemove(i);
        }
        self.pool.help(&self.main_context, false);
        try self.collect(arena, frame);
        mesh_ns += self.since(t);
    }

    if (self.settled) return;

    // add generated columns, up to the budget
    var generated: u32 = 0;
    {
        const t = self.now();
        while (generated < config.gen_budget and self.ready_columns.items.len > 0) {
            generated += try self.addColumn(self.ready_columns.orderedRemove(0), center, r, config);
        }
        gen_ns += self.since(t);
    }

    // generate one ring beyond the view distance so edge chunks have neighbors to mesh
    // against; nearest columns first
    var columns_left = false;
    const max_gen_jobs = gen_jobs_per_worker * @max(self.pool.workers, 1);
    for (self.offsets.items) |off| {
        if (@max(@abs(off[0]), @abs(off[1])) > r + 1) continue;
        const column = [2]i32{ center.x + off[0], center.z + off[1] };
        if (self.columns_in_flight.contains(column) or !self.columnMissing(column, config)) continue;
        if (self.gen_in_flight + self.ready_columns.items.len >= max_gen_jobs) {
            columns_left = true;
            break;
        }
        const t = self.now();
        try self.submitColumn(column, config);
        gen_ns += self.since(t);
    }

    var meshed: u32 = 0;
    var pending: u32 = 0;
    const max_mesh_jobs = mesh_jobs_per_worker * @max(self.pool.workers, 1);
    for (self.offsets.items) |off| {
        if (@max(@abs(off[0]), @abs(off[1])) > r) continue;
        var y = config.min_y;
        while (y <= config.max_y) : (y += 1) {
            const pos: ChunkPos = .{ .x = center.x + off[0], .y = y, .z = center.z + off[1] };
            const c = self.chunks.get(pos) orelse {
                pending += 1;
                continue;
            };
            if (c.state == .meshed) continue;
            if (c.state == .meshing or meshed >= config.mesh_budget or self.mesh_in_flight >= max_mesh_jobs or
                !self.neighborsLoaded(pos))
            {
                pending += 1;
                continue;
            }
            const t = self.now();
            try self.submitMesh(arena, c, frame, false);
            mesh_ns += self.since(t);
            meshed += 1;
            if (c.state == .meshing) pending += 1;
        }
    }

    // without workers, the jobs run here
    if (self.pool.workers == 0) {
        self.pool.runQueued(&self.main_context, std.math.maxInt(usize));
        const t = self.now();
        try self.collect(arena, frame);
        mesh_ns += self.since(t);
    }

    self.settled = pending == 0 and !columns_left and self.gen_in_flight == 0 and
        self.ready_columns.items.len == 0 and self.mesh_in_flight == 0;
    self.stats.loaded = self.chunks.count();
    self.stats.generated_this_frame = generated;
    self.stats.meshed_this_frame = meshed;
    self.stats.pending = pending;
    self.stats.gen_total += generated;
    self.stats.gen_total_ns += gen_ns;
    self.stats.mesh_total_ns += mesh_ns;
}

/// Whether column (x, z) misses a chunk in the generated y range.
fn columnMissing(self: *const Self, column: [2]i32, config: Config) bool {
    var y = config.min_y - 1;
    while (y <= config.max_y + 1) : (y += 1) {
        if (!self.chunks.contains(.{ .x = column[0], .y = y, .z = column[1] })) return true;
    }
    return false;
}

/// Starts generating a column on the workers.
fn submitColumn(self: *Self, column: [2]i32, config: Config) !void {
    const job = if (self.free_gen_jobs.pop()) |job| job else blk: {
        try self.gen_jobs.ensureUnusedCapacity(self.allocator, 1);
        try self.free_gen_jobs.ensureTotalCapacity(self.allocator, self.gen_jobs.items.len + 1);
        const job = try self.allocator.create(GenJob);
        errdefer self.allocator.destroy(job);
        job.* = .{ .terrain = undefined, .epoch = undefined, .column = undefined, .top = undefined, .bottom = undefined, .map = try self.allocator.create(Terrain.Heightmap) };
        self.gen_jobs.appendAssumeCapacity(job);
        break :blk job;
    };
    errdefer self.free_gen_jobs.appendAssumeCapacity(job);
    job.terrain = self.terrain;
    job.epoch = self.epoch;
    job.column = column;
    job.top = config.max_y + 1;
    job.bottom = config.min_y - 1;
    job.err = null;
    errdefer job.freeChunks(self.allocator);
    var y = job.top;
    while (y >= job.bottom) : (y -= 1) {
        try job.saved.append(self.allocator, null);
        job.saved.items[job.saved.items.len - 1] = try self.save.load(self.allocator, .{ .x = column[0], .y = y, .z = column[1] });
    }
    try self.columns_in_flight.put(self.allocator, column, {});
    errdefer _ = self.columns_in_flight.remove(column);
    try self.pool.submit(&job.job);
    self.gen_in_flight += 1;
}

fn releaseGenJob(self: *Self, job: *GenJob) void {
    job.freeChunks(self.allocator);
    // the list has room for every job
    self.free_gen_jobs.appendAssumeCapacity(job);
}

/// Starts meshing chunk `c` on the workers; `urgent` ones go first. Buried chunks get
/// an empty mesh right away.
fn submitMesh(self: *Self, arena: *MeshArena, c: *Chunk, frame: u64, urgent: bool) !void {
    if (self.buried(c)) {
        self.stats.mesh_skipped += 1;
        try freeMeshes(arena, c, frame);
        c.mesh_job = 0;
        c.state = .meshed;
        return;
    }
    const job = if (self.free_mesh_jobs.pop()) |job| job else blk: {
        try self.mesh_jobs.ensureUnusedCapacity(self.allocator, 1);
        try self.free_mesh_jobs.ensureTotalCapacity(self.allocator, self.mesh_jobs.items.len + 1);
        const job = try self.allocator.create(MeshJob);
        job.* = .{};
        self.mesh_jobs.appendAssumeCapacity(job);
        break :blk job;
    };
    errdefer self.free_mesh_jobs.appendAssumeCapacity(job);
    job.job.urgent = urgent;
    job.pos = c.pos;
    job.id = self.next_job_id;
    job.options = self.mesh_options;
    job.err = null;
    self.fillPadded(c.pos, &job.padded, &job.padded_light);
    try self.pool.submit(&job.job);
    self.next_job_id += 1;
    self.mesh_in_flight += 1;
    c.mesh_job = job.id;
    c.state = .meshing;
}

/// Takes in the jobs the workers finished: uploads meshes, and queues generated
/// columns in `ready_columns`.
fn collect(self: *Self, arena: *MeshArena, frame: u64) !void {
    self.finished_jobs.clearRetainingCapacity();
    try self.pool.poll(&self.finished_jobs);
    for (self.finished_jobs.items) |job| {
        if (job.run == &GenJob.run) {
            try self.takeColumn(@fieldParentPtr("job", job));
        } else {
            const mesh: *MeshJob = @fieldParentPtr("job", job);
            self.mesh_in_flight -= 1;
            // the list has room for every job
            defer self.free_mesh_jobs.appendAssumeCapacity(mesh);
            self.stats.mesh_total += 1;
            self.stats.mesh_total_ns += mesh.ns;
            if (mesh.err) |err| return err;
            // dropped, or meshed again since
            const c = self.chunks.get(mesh.pos) orelse continue;
            if (c.mesh_job != mesh.id) continue;
            c.mesh_job = 0;
            try freeMeshes(arena, c, frame);
            // an edit since the job started leaves it `generated`, to be meshed again
            if (c.state == .meshing) c.state = .meshed;
            c.mesh = try self.upload(arena, mesh.out.solid.items);
            c.translucent_mesh = try self.upload(arena, mesh.out.translucent.items);
        }
    }
    self.stats.gen_jobs = self.gen_in_flight + @as(u32, @intCast(self.ready_columns.items.len));
    self.stats.mesh_jobs = self.mesh_in_flight;
}

/// Queues a generated column for `addColumn`, unless it was generated before a
/// `regenerate`.
fn takeColumn(self: *Self, job: *GenJob) !void {
    self.gen_in_flight -= 1;
    if (job.epoch != self.epoch) {
        self.releaseGenJob(job);
        return;
    }
    self.stats.gen_total_ns += job.ns;
    errdefer {
        _ = self.columns_in_flight.remove(job.column);
        self.releaseGenJob(job);
    }
    if (job.err) |err| return err;
    try self.ready_columns.append(self.allocator, job);
}

/// Adds the chunks of a generated column to the world, top down, unless it went out
/// of range meanwhile, and returns how many were added.
fn addColumn(self: *Self, job: *GenJob, center: ChunkPos, r: i32, config: Config) !u32 {
    defer self.releaseGenJob(job);
    _ = self.columns_in_flight.remove(job.column);
    if (@abs(job.column[0] - center.x) > r + 2 or @abs(job.column[1] - center.z) > r + 2) return 0;
    if (!self.heightmaps.contains(job.column)) {
        const map = try self.allocator.create(Terrain.Heightmap);
        errdefer self.allocator.destroy(map);
        map.* = job.map.*;
        try self.heightmaps.put(self.allocator, job.column, map);
    }
    const map = self.heightmaps.get(job.column).?;

    var added: u32 = 0;
    // below a chunk that was loaded already (kept for its edits), the light falling in
    // differs from what the worker saw: light those chunks from scratch
    var relight = self.chunks.contains(.{ .x = job.column[0], .y = job.top + 1, .z = job.column[1] });
    while (job.chunks.items.len > 0) {
        const c = job.chunks.orderedRemove(0);
        if (c.pos.y < config.min_y - 1 or c.pos.y > config.max_y + 1 or self.chunks.contains(c.pos)) {
            freeChunk(self.allocator, c);
            relight = true;
            continue;
        }
        self.chunks.put(self.allocator, c.pos, c) catch |err| {
            freeChunk(self.allocator, c);
            return err;
        };
        added += 1;
        if (relight) {
            if (c.light) |l| self.allocator.destroy(l);
            c.light = null;
            c.uniform_light = 0;
            c.has_block_light = false;
            try light.initChunk(self, c, map);
        } else {
            try light.integrateChunk(self, c);
        }
    }
    return added;
}

/// Whether every chunk of column (x, z) in the configured y range has a mesh
/// (possibly empty, possibly being rebuilt), so the column can be drawn without holes.
pub fn columnReady(self: *const Self, x: i32, z: i32, config: Config) bool {
    var y = config.min_y;
    while (y <= config.max_y) : (y += 1) {
        const c = self.chunks.get(.{ .x = x, .y = y, .z = z }) orelse return false;
        if (c.state != .meshed and c.mesh == null and c.translucent_mesh == null) return false;
    }
    return true;
}

/// Records draws for the solid mesh of every chunk in view, limited to `columns` when
/// given (the rest is covered by distant terrain), and collects the translucent meshes
/// for `drawTranslucent`. Expects `pipeline.bind(..., .solid)` to have been called.
pub fn draw(self: *Self, cmd: vk.CommandBuffer, pipeline: *const VoxelPipeline, camera_pos: @Vector(3, f64), frustum: ?math.Frustum, config: Config, columns: ?*const ColumnSet) void {
    const start = self.now();
    const center = ChunkPos.fromWorld(camera_pos);
    const r = @max(config.render_distance, 0);
    var drawn: u32 = 0;
    var meshed: u32 = 0;
    var vertices: u64 = 0;
    self.translucent_draws.clearRetainingCapacity();

    var it = self.chunks.valueIterator();
    while (it.next()) |entry| {
        const c = entry.*;
        if (c.mesh == null and c.translucent_mesh == null) continue;
        meshed += 1;
        if (@abs(c.pos.x - center.x) > r or @abs(c.pos.z - center.z) > r) continue;
        if (c.pos.y < config.min_y or c.pos.y > config.max_y) continue;
        if (columns) |set| if (!set.contains(.{ c.pos.x, c.pos.z })) continue;

        const origin: math.Vec3 = @floatCast(c.pos.origin() - camera_pos);
        if (frustum) |f| {
            if (!f.intersectsAabb(origin, origin + @as(math.Vec3, @splat(chunk.size)))) continue;
        }
        if (c.mesh) |range| {
            pipeline.drawChunk(cmd, origin, range, 1);
            vertices += range.count;
        }
        if (c.translucent_mesh) |range| {
            const center_offset = origin + @as(math.Vec3, @splat(chunk.size / 2));
            // without room to sort, the chunk's water and glass are skipped this frame
            self.translucent_draws.append(self.allocator, .{ .distance = math.length(center_offset), .origin = origin, .range = range }) catch {};
            vertices += range.count;
        }
        drawn += 1;
    }

    // farthest first, so nearer surfaces blend over farther ones
    std.mem.sort(TranslucentDraw, self.translucent_draws.items, {}, struct {
        fn farther(_: void, a: TranslucentDraw, b: TranslucentDraw) bool {
            return a.distance > b.distance;
        }
    }.farther);

    self.stats.meshed = meshed;
    self.stats.drawn = drawn;
    self.stats.drawn_vertices = vertices;
    self.stats.draw_ms = toMs(self.since(start));
}

/// Records the translucent meshes collected by the last `draw`. Expects
/// `pipeline.bind(..., .translucent)` to have been called.
pub fn drawTranslucent(self: *const Self, cmd: vk.CommandBuffer, pipeline: *const VoxelPipeline) void {
    for (self.translucent_draws.items) |d| pipeline.drawChunk(cmd, d.origin, d.range, 1);
}

fn now(self: *const Self) std.Io.Timestamp {
    return .now(self.io, .awake);
}

fn since(self: *const Self, start: std.Io.Timestamp) u64 {
    return @intCast(@max(start.untilNow(self.io, .awake).nanoseconds, 0));
}

fn toMs(ns: u64) f32 {
    return @floatCast(@as(f64, @floatFromInt(ns)) / std.time.ns_per_ms);
}

fn buildOffsets(self: *Self, r: i32) !void {
    self.offsets.clearRetainingCapacity();
    const extent = r + 2;
    var z = -extent;
    while (z <= extent) : (z += 1) {
        var x = -extent;
        while (x <= extent) : (x += 1) try self.offsets.append(self.allocator, .{ x, z });
    }
    std.mem.sort([2]i32, self.offsets.items, {}, struct {
        fn lessThan(_: void, a: [2]i32, b: [2]i32) bool {
            return a[0] * a[0] + a[1] * a[1] < b[0] * b[0] + b[1] * b[1];
        }
    }.lessThan);
    self.offsets_radius = r;
}

fn unloadFar(self: *Self, arena: *MeshArena, center: ChunkPos, r: i32, config: Config, frame: u64) !void {
    self.scratch_keys.clearRetainingCapacity();
    var it = self.chunks.iterator();
    while (it.next()) |entry| {
        const pos = entry.key_ptr.*;
        const far = @abs(pos.x - center.x) > r + 2 or @abs(pos.z - center.z) > r + 2;
        const out_of_range = pos.y < config.min_y - 1 or pos.y > config.max_y + 1;
        if (far or out_of_range) try self.scratch_keys.append(self.allocator, pos);
    }
    for (self.scratch_keys.items) |pos| {
        const c = self.chunks.get(pos).?;
        try freeMeshes(arena, c, frame);
        if (c.modified) {
            try self.save.store(pos, c.blocks, c.uniform);
            c.modified = false;
        }
        _ = self.chunks.remove(pos);
        self.destroyChunk(c);
    }

    self.scratch_columns.clearRetainingCapacity();
    var columns = self.heightmaps.keyIterator();
    while (columns.next()) |column| {
        if (@abs(column[0] - center.x) > r + 2 or @abs(column[1] - center.z) > r + 2) {
            try self.scratch_columns.append(self.allocator, column.*);
        }
    }
    for (self.scratch_columns.items) |column| {
        self.allocator.destroy(self.heightmaps.fetchRemove(column).?.value);
    }
}

fn clearHeightmaps(self: *Self) void {
    var it = self.heightmaps.valueIterator();
    while (it.next()) |map| self.allocator.destroy(map.*);
    self.heightmaps.clearRetainingCapacity();
}

/// The column's heightmap, computed on first use.
fn heightmap(self: *Self, x: i32, z: i32) !*const Terrain.Heightmap {
    if (self.heightmaps.get(.{ x, z })) |map| return map;
    const map = try self.allocator.create(Terrain.Heightmap);
    errdefer self.allocator.destroy(map);
    self.terrain.heightmap(x, z, map);
    try self.heightmaps.put(self.allocator, .{ x, z }, map);
    return map;
}

/// Generates and lights one chunk on the calling thread (the workers generate whole
/// columns; see `GenJob`).
fn generateChunk(self: *Self, pos: ChunkPos) !void {
    const map = try self.heightmap(pos.x, pos.z);
    const c = try buildChunk(self.allocator, self.terrain, pos, map, try self.save.load(self.allocator, pos));
    errdefer self.destroyChunk(c);
    try self.chunks.put(self.allocator, pos, c);
    errdefer _ = self.chunks.remove(pos);
    try light.initChunk(self, c, map);
}

/// The blocks of a new chunk, not lit yet: `saved` (which it takes over) or else the
/// terrain's.
fn buildChunk(allocator: Allocator, terrain: Terrain, pos: ChunkPos, map: *const Terrain.Heightmap, saved: ?*chunk.Blocks) !*Chunk {
    const c = allocator.create(Chunk) catch |err| {
        if (saved) |blocks| allocator.destroy(blocks);
        return err;
    };
    c.* = .{ .pos = pos };
    errdefer freeChunk(allocator, c);

    if (saved) |blocks| {
        if (std.mem.allEqual(BlockId, blocks, blocks[0])) {
            c.uniform = blocks[0];
            allocator.destroy(blocks);
        } else {
            c.blocks = blocks;
        }
        c.updateSolidSides();
        return c;
    }
    switch (Terrain.classify(pos.y, map)) {
        .uniform => |block| {
            c.uniform = block;
            // nothing to mesh in an all-air chunk
            if (block == .air) c.state = .meshed;
        },
        .mixed => {
            const blocks = try allocator.create(chunk.Blocks);
            terrain.fill(pos.y, map, blocks);
            c.blocks = blocks;
        },
    }
    c.updateSolidSides();
    return c;
}

fn freeMeshes(arena: *MeshArena, c: *Chunk, frame: u64) !void {
    if (c.mesh) |range| try arena.free(range, frame);
    if (c.translucent_mesh) |range| try arena.free(range, frame);
    c.mesh = null;
    c.translucent_mesh = null;
}

fn destroyChunk(self: *Self, c: *Chunk) void {
    freeChunk(self.allocator, c);
}

fn freeChunk(allocator: Allocator, c: *Chunk) void {
    if (c.blocks) |blocks| allocator.destroy(blocks);
    if (c.light) |l| allocator.destroy(l);
    allocator.destroy(c);
}

fn neighborsLoaded(self: *const Self, pos: ChunkPos) bool {
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (!self.chunks.contains(pos.offset(dx, dy, dz))) return false;
            }
        }
    }
    return true;
}

/// True when no face of the chunk can be visible: it is solid and each face
/// neighbor's side touching it is solid too.
fn buried(self: *const Self, c: *const Chunk) bool {
    if (!c.isSolid()) return false;
    // same side order as `Chunk.solid_sides`; side ^ 1 is the opposite side
    const neighbors = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
    for (neighbors, 0..) |d, side| {
        const n = self.chunks.get(c.pos.offset(d[0], d[1], d[2])) orelse return false;
        if (n.solid_sides & (@as(u6, 1) << @intCast(side ^ 1)) == 0) return false;
    }
    return true;
}

/// Null when there is nothing to upload or the arena is full.
fn upload(self: *Self, arena: *MeshArena, vertices: []const mesher.Vertex) !?chunk.MeshRange {
    if (vertices.len == 0) return null;
    const range = try arena.upload(vertices);
    if (range == null and !self.stats.arena_full) {
        log.warn("mesh arena is full ({d} vertices); increase its capacity or lower the render distance", .{arena.capacity});
        self.stats.arena_full = true;
    }
    return range;
}

/// Copies the blocks and light of the chunk and a one-block border of its 26 neighbors
/// into `padded` and `padded_light`.
fn fillPadded(self: *const Self, pos: ChunkPos, padded: *mesher.Padded, padded_light: *mesher.PaddedLight) void {
    var neighbors: [3][3][3]?*const Chunk = undefined;
    for (0..3) |y| {
        for (0..3) |z| {
            for (0..3) |x| {
                neighbors[y][z][x] = self.chunks.get(pos.offset(@as(i32, @intCast(x)) - 1, @as(i32, @intCast(y)) - 1, @as(i32, @intCast(z)) - 1));
            }
        }
    }

    // per padded y or z: which neighbor (0..2) and the local coordinate inside it
    const Axis = struct { n: usize, local: usize };
    var axis: [mesher.padded_size]Axis = undefined;
    for (&axis, 0..) |*a, p| {
        a.* = if (p == 0)
            .{ .n = 0, .local = chunk.size - 1 }
        else if (p == mesher.padded_size - 1)
            .{ .n = 2, .local = 0 }
        else
            .{ .n = 1, .local = p - 1 };
    }

    for (axis, 0..) |ay, py| {
        for (axis, 0..) |az, pz| {
            const row = mesher.paddedIndex(0, py, pz);
            const n = neighbors[ay.n][az.n];
            // the ends of the row come from the neighbors in x
            for ([_]usize{ 0, 2 }, [_]usize{ 0, mesher.padded_size - 1 }, [_]usize{ chunk.size - 1, 0 }) |nx, px, lx| {
                const i = chunk.index(lx, ay.local, az.local);
                padded[row + px] = if (n[nx]) |c| c.getIndex(i) else .air;
                padded_light[row + px] = if (n[nx]) |c| c.getLight(i) else 0xf0;
            }
            // the middle is one row of the chunk in the middle
            const blocks = padded[row + 1 ..][0..chunk.size];
            const lights = padded_light[row + 1 ..][0..chunk.size];
            const start = chunk.index(0, ay.local, az.local);
            if (n[1]) |c| {
                if (c.blocks) |b| @memcpy(blocks, b[start..][0..chunk.size]) else @memset(blocks, c.uniform);
                if (c.light) |l| @memcpy(lights, l[start..][0..chunk.size]) else @memset(lights, c.uniform_light);
            } else {
                @memset(blocks, .air);
                @memset(lights, 0xf0);
            }
        }
    }
}

const testing = std.testing;

/// A world with chunks x, z in [-1, 1] and y in [-1, 3] generated, top down as `update` does.
fn testWorld() !Self {
    return testWorldAround(0, 0);
}

/// As `testWorld`, around chunk column (x, z).
fn testWorldAround(x: i32, z: i32) !Self {
    var world = try Self.init(testing.allocator, testing.io, 7);
    errdefer world.deinit();
    var cx: i32 = x - 1;
    while (cx <= x + 1) : (cx += 1) {
        var cz: i32 = z - 1;
        while (cz <= z + 1) : (cz += 1) {
            var cy: i32 = 3;
            while (cy >= -1) : (cy -= 1) try world.generateChunk(.{ .x = cx, .y = cy, .z = cz });
        }
    }
    return world;
}

fn sky(world: *const Self, x: i32, y: i32, z: i32) u4 {
    return light.level(world.getLight(x, y, z).?, .sky);
}

fn blockLight(world: *const Self, x: i32, y: i32, z: i32) u4 {
    return light.level(world.getLight(x, y, z).?, .block);
}

/// A column inside chunk (0, 0) with open sky at least 12 blocks above dry ground,
/// below the generated height range.
fn openColumn(world: *const Self) [3]i32 {
    var x: i32 = 6;
    while (x < 26) : (x += 1) {
        var z: i32 = 6;
        next: while (z < 26) : (z += 1) {
            const h = world.terrain.height(x, z);
            if (h <= Terrain.sea_level or h + 14 >= 4 * chunk.size) continue;
            var y = h + 1;
            while (y <= h + 14) : (y += 1) {
                if (world.getBlock(x, y, z) != .air) continue :next;
            }
            return .{ x, h, z };
        }
    }
    unreachable;
}

test "sky light is full in the open and dark underground" {
    var world = try testWorld();
    defer world.deinit();
    const col = openColumn(&world);
    const x, const h, const z = col;
    try testing.expectEqual(@as(u4, 15), sky(&world, x, h + 1, z));
    try testing.expectEqual(@as(u4, 15), sky(&world, x, h + 10, z));
    try testing.expectEqual(@as(u4, 0), sky(&world, x, h - 3, z));
}

test "a roof casts a shadow and breaking it lets the sun back in" {
    var world = try testWorld();
    defer world.deinit();
    const x, const h, const z = openColumn(&world);
    try world.setBlock(x, h + 4, z, .stone);
    // lit from the side now, one level less
    try testing.expectEqual(@as(u4, 14), sky(&world, x, h + 3, z));
    try testing.expectEqual(@as(u4, 0), sky(&world, x, h + 4, z));
    try world.setBlock(x, h + 4, z, .air);
    try testing.expectEqual(@as(u4, 15), sky(&world, x, h + 3, z));
    try testing.expectEqual(@as(u4, 15), sky(&world, x, h + 4, z));
}

test "a lamp lights its surroundings until it is removed" {
    var world = try testWorld();
    defer world.deinit();
    const x, const h, const z = openColumn(&world);
    try world.setBlock(x, h + 6, z, .lamp);
    try testing.expectEqual(@as(u4, 15), blockLight(&world, x, h + 6, z));
    try testing.expectEqual(@as(u4, 14), blockLight(&world, x, h + 7, z));
    try testing.expectEqual(@as(u4, 12), blockLight(&world, x, h + 9, z));
    try testing.expectEqual(@as(u4, 13), blockLight(&world, x + 1, h + 7, z));
    try world.setBlock(x, h + 6, z, .air);
    try testing.expectEqual(@as(u4, 0), blockLight(&world, x, h + 6, z));
    try testing.expectEqual(@as(u4, 0), blockLight(&world, x, h + 9, z));
    // the sky came back too
    try testing.expectEqual(@as(u4, 15), sky(&world, x, h + 6, z));
}

test "light is the same whichever chunk loads first" {
    // generating bottom up leaves no chunk above to fall back on, so this relies on
    // the heightmap estimate and the exchange between neighbors
    var a = try testWorld();
    defer a.deinit();
    var b = try Self.init(testing.allocator, testing.io, 7);
    defer b.deinit();
    var cy: i32 = -1;
    while (cy <= 3) : (cy += 1) {
        var cx: i32 = 1;
        while (cx >= -1) : (cx -= 1) {
            var cz: i32 = -1;
            while (cz <= 1) : (cz += 1) try b.generateChunk(.{ .x = cx, .y = cy, .z = cz });
        }
    }
    // the middle chunks, away from the unloaded outside
    var differing: usize = 0;
    var y: i32 = 0;
    while (y < 3 * chunk.size) : (y += 1) {
        var z: i32 = 0;
        while (z < chunk.size) : (z += 1) {
            var x: i32 = 0;
            while (x < chunk.size) : (x += 1) {
                if (a.getLight(x, y, z).? != b.getLight(x, y, z).?) differing += 1;
            }
        }
    }
    // only under tree canopies that cross a chunk boundary, which the estimate can't see
    try testing.expect(differing < 64);
}

test "sky light fades with depth under water" {
    // the first column along +x deep under the sea
    const terrain: Terrain = .{ .seed = 7 };
    var x: i32 = 0;
    while (terrain.height(x, 0) >= Terrain.sea_level - 3) : (x += 1) {
        if (x > 100_000) return error.SkipZigTest;
    }
    var world = try testWorldAround(@divFloor(x, chunk.size), 0);
    defer world.deinit();
    try testing.expectEqual(@as(u4, 14), sky(&world, x, Terrain.sea_level, 0));
    try testing.expectEqual(@as(u4, 12), sky(&world, x, Terrain.sea_level - 2, 0));
}

/// Generates the chunks of `testWorld` as `update` does: in columns, on 2 workers.
fn generateOnWorkers(world: *Self) !void {
    world.startWorkers(2);
    // the y range of `testWorld`
    const config: Config = .{ .render_distance = 1, .min_y = 0, .max_y = 2, .gen_budget = 1000, .mesh_budget = 0 };
    var cx: i32 = -1;
    while (cx <= 1) : (cx += 1) {
        var cz: i32 = -1;
        while (cz <= 1) : (cz += 1) try world.submitColumn(.{ cx, cz }, config);
    }
    world.pool.help(&world.main_context, true);
    try world.pool.poll(&world.finished_jobs);
    for (world.finished_jobs.items) |job| try world.takeColumn(@fieldParentPtr("job", job));
    try testing.expectEqual(9, world.ready_columns.items.len);
    // in whatever order they finished
    while (world.ready_columns.items.len > 0) {
        _ = try world.addColumn(world.ready_columns.orderedRemove(0), .{ .x = 0, .y = 0, .z = 0 }, 1, config);
    }
}

test "columns generated on the workers are lit like chunks generated one by one" {
    var a = try testWorld();
    defer a.deinit();
    var b = try Self.init(testing.allocator, testing.io, 7);
    defer b.deinit();
    try generateOnWorkers(&b);
    try testing.expectEqual(a.chunks.count(), b.chunks.count());
    var it = a.chunks.iterator();
    while (it.next()) |entry| {
        const ca = entry.value_ptr.*;
        const cb = b.chunks.get(entry.key_ptr.*).?;
        for (0..chunk.volume) |i| {
            try testing.expectEqual(ca.getIndex(i), cb.getIndex(i));
            try testing.expectEqual(ca.getLight(i), cb.getLight(i));
        }
    }
}

test "edits are saved and come back, lit, when the world is loaded again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var x: i32 = undefined;
    var h: i32 = undefined;
    var z: i32 = undefined;
    {
        var world = try testWorld();
        defer world.deinit();
        try world.openSave(tmp.dir);
        x, h, z = openColumn(&world);
        try world.setBlock(x, h + 4, z, .planks);
        try world.saveAll();
    }
    var world = try Self.init(testing.allocator, testing.io, 7);
    defer world.deinit();
    try world.openSave(tmp.dir);
    try generateOnWorkers(&world);
    try testing.expectEqual(BlockId.planks, world.getBlock(x, h + 4, z).?);
    try testing.expect(!world.chunks.get(ChunkPos.fromBlock(x, h + 4, z)).?.modified);
    // the shadow under it, as when it was placed
    try testing.expectEqual(@as(u4, 14), sky(&world, x, h + 3, z));
}
