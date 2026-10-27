//! A pool of worker threads running jobs (chunk generation and meshing) off the main
//! thread. Jobs never touch the live world: they get copies of their inputs and hand
//! their results back to the main thread through `poll`.
//!
//! Without workers (no concurrency available) the jobs run on the main thread, in
//! `runQueued` or `help`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const light = @import("light.zig");

const log = std.log.scoped(.workers);

const Pool = @This();

/// Embedded in a job struct; `run` gets the job back with `@fieldParentPtr`.
pub const Job = struct {
    run: *const fn (*Job, *Context) void,
    /// runs before every non-urgent job (edits)
    urgent: bool = false,
};

/// Per-thread scratch memory for jobs.
pub const Context = struct {
    allocator: Allocator,
    io: Io,
    light_queues: *light.Queues,

    pub fn create(allocator: Allocator, io: Io) !Context {
        const q = try allocator.create(light.Queues);
        q.* = .{};
        return .{ .allocator = allocator, .io = io, .light_queues = q };
    }

    pub fn destroy(self: *Context) void {
        self.light_queues.deinit(self.allocator);
        self.allocator.destroy(self.light_queues);
    }
};

io: Io,
allocator: Allocator,
mutex: Io.Mutex = .init,
/// signaled when a job is queued or the pool is closing
queued: Io.Condition = .init,
/// signaled when a job finishes
finished: Io.Condition = .init,
urgent: std.ArrayList(*Job) = .empty,
normal: std.ArrayList(*Job) = .empty,
done: std.ArrayList(*Job) = .empty,
/// queued or running jobs, and the urgent ones among them
outstanding: usize = 0,
urgent_outstanding: usize = 0,
closing: bool = false,
group: Io.Group = .init,
workers: usize = 0,

/// Starts up to `count` workers; `self` must stay at the same address until `deinit`.
pub fn start(self: *Pool, count: usize) void {
    for (0..count) |_| {
        self.group.concurrent(self.io, worker, .{self}) catch |err| {
            log.warn("started {d} of {d} workers: {t}", .{ self.workers, count, err });
            break;
        };
        self.workers += 1;
    }
}

/// Stops the workers once their current jobs finish. Jobs still queued or never
/// polled stay with their owner, which frees them.
pub fn deinit(self: *Pool) void {
    self.mutex.lockUncancelable(self.io);
    self.closing = true;
    self.queued.broadcast(self.io);
    self.mutex.unlock(self.io);
    self.group.await(self.io) catch {};
    self.urgent.deinit(self.allocator);
    self.normal.deinit(self.allocator);
    self.done.deinit(self.allocator);
}

/// Worker count to use on this machine: the cores left over by the main thread and one
/// more for the rest of the system.
pub fn defaultWorkerCount() usize {
    const cpus = std.Thread.getCpuCount() catch return 1;
    return std.math.clamp(cpus -| 2, 1, 16);
}

pub fn submit(self: *Pool, job: *Job) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    // room for every job in flight to finish, so `complete` can't fail
    try self.done.ensureTotalCapacity(self.allocator, self.done.items.len + self.outstanding + 1);
    try (if (job.urgent) &self.urgent else &self.normal).append(self.allocator, job);
    self.outstanding += 1;
    if (job.urgent) self.urgent_outstanding += 1;
    self.queued.signal(self.io);
}

/// Moves the finished jobs into `out`, without waiting.
pub fn poll(self: *Pool, out: *std.ArrayList(*Job)) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try out.appendSlice(self.allocator, self.done.items);
    self.done.clearRetainingCapacity();
}

/// Jobs queued or running.
pub fn pending(self: *Pool) usize {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.outstanding;
}

/// Waits until every urgent job (or, with `all`, every job) has finished, running
/// queued jobs on this thread meanwhile.
pub fn help(self: *Pool, ctx: *Context, all: bool) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    while ((if (all) self.outstanding else self.urgent_outstanding) > 0) {
        if (self.take(all)) |job| {
            self.mutex.unlock(self.io);
            job.run(job, ctx);
            self.mutex.lockUncancelable(self.io);
            self.complete(job);
        } else {
            self.finished.waitUncancelable(self.io, &self.mutex);
        }
    }
}

/// Runs up to `max` queued jobs on this thread; for running without workers.
pub fn runQueued(self: *Pool, ctx: *Context, max: usize) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (0..max) |_| {
        const job = self.take(true) orelse return;
        self.mutex.unlock(self.io);
        job.run(job, ctx);
        self.mutex.lockUncancelable(self.io);
        self.complete(job);
    }
}

/// The next queued job, urgent ones first; expects the mutex to be held.
fn take(self: *Pool, any: bool) ?*Job {
    if (self.urgent.items.len > 0) return self.urgent.orderedRemove(0);
    if (any and self.normal.items.len > 0) return self.normal.orderedRemove(0);
    return null;
}

/// Records a finished job; expects the mutex to be held.
fn complete(self: *Pool, job: *Job) void {
    self.done.appendAssumeCapacity(job);
    self.outstanding -= 1;
    if (job.urgent) self.urgent_outstanding -= 1;
    self.finished.broadcast(self.io);
}

fn worker(self: *Pool) void {
    var ctx = Context.create(self.allocator, self.io) catch |err| {
        log.err("worker failed to start: {t}", .{err});
        return;
    };
    defer ctx.destroy();

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    while (true) {
        // jobs still queued are left to the owner
        if (self.closing) return;
        if (self.take(true)) |job| {
            self.mutex.unlock(self.io);
            job.run(job, &ctx);
            self.mutex.lockUncancelable(self.io);
            self.complete(job);
        } else {
            self.queued.waitUncancelable(self.io, &self.mutex);
        }
    }
}

const testing = std.testing;

const TestJob = struct {
    job: Job = .{ .run = run },
    value: u64,
    result: u64 = 0,

    fn run(job: *Job, _: *Context) void {
        const self: *TestJob = @fieldParentPtr("job", job);
        self.result = self.value * self.value;
    }
};

test "jobs run on the workers and come back through poll" {
    var pool: Pool = .{ .io = testing.io, .allocator = testing.allocator };
    pool.start(2);
    defer pool.deinit();
    var ctx = try Context.create(testing.allocator, testing.io);
    defer ctx.destroy();

    var jobs: [16]TestJob = undefined;
    for (&jobs, 0..) |*j, i| {
        j.* = .{ .value = i, .job = .{ .run = TestJob.run, .urgent = i % 4 == 0 } };
        try pool.submit(&j.job);
    }
    pool.help(&ctx, true);
    var finished: std.ArrayList(*Job) = .empty;
    defer finished.deinit(testing.allocator);
    try pool.poll(&finished);
    try testing.expectEqual(jobs.len, finished.items.len);
    for (jobs, 0..) |j, i| try testing.expectEqual(i * i, j.result);
}
