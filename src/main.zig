const std = @import("std");
const fifo = std.fifo;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

fn GPoll(comptime T: type) type {
    return union(enum) {
        pending: void,
        ready: T,
    };
}

fn GFuture(comptime T: type) type {
    return struct {
        ptr: *anyopaque,
        pollfn: *const fn (ctx: *anyopaque, waker: Waker) GPoll(T),
        const Self = @This();

        fn poll(self: *const Self, waker: Waker) GPoll(T) {
            return self.pollfn(self.ptr, waker);
        }
    };
}

// Waker Interface
const Waker = struct {
    ptr: *anyopaque,
    wakefn: *const fn (ctx: *anyopaque) void,

    fn wake(self: *const Waker) void {
        self.wakefn(self.ptr);
    }
};

// Here a Executor implementation for this interface

fn GJoinHandle(comptime T: type) type {
    return struct {
        result: ?T = null,
    };
}

const TaskVTable = struct {
    pollReady: *const fn (ctx: *anyopaque) bool,
    getId: *const fn (ctx: *anyopaque) usize,
};

const TaskInterface = struct {
    ptr: *anyopaque,
    tasksize: usize,
    vtable: TaskVTable,

    const Self = @This();

    fn pollReady(self: Self) bool {
        return self.vtable.pollReady(self.ptr);
    }

    fn getId(self: Self) usize {
        return self.vtable.getId(self.ptr);
    }
};

fn GTask(comptime T: type) type {
    return struct {
        id: usize,
        future: GFuture(T),
        joinhandle: ?*GJoinHandle(T),
        executor: *GExecutor,

        const Self = @This();

        fn getWaker(self: *Self) Waker {
            return Waker{
                .wakefn = Self.wake,
                .ptr = self,
            };
        }

        fn pollReady(ctx: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            switch (self.future.poll(self.getWaker())) {
                GPoll(T).pending => return false,
                GPoll(T).ready => |val| {
                    std.debug.print("Ready Task {d}: {d}\n", .{ self.id, val });
                    if (self.joinhandle) |jh| {
                        jh.result = val;
                    }
                    return true;
                },
            }
        }

        fn getId(ctx: *anyopaque) usize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.id;
        }

        fn wake(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.executor.wakeTask(self.id);
        }

        fn task(self: *Self) TaskInterface {
            return TaskInterface{
                .ptr = self,
                .tasksize = @sizeOf(Self),
                .vtable = TaskVTable{
                    .getId = Self.getId,
                    .pollReady = Self.pollReady,
                },
            };
        }
    };
}

const GExecutor = struct {
    const FutureFifo = fifo.LinearFifo(usize, fifo.LinearFifoBufferType{ .Static = 32 });

    taskqueue: FutureFifo,
    taskmemory: [32]?TaskInterface,
    pending: u64,
    allocator: Allocator,

    const Self = @This();

    fn init(allocator: Allocator) Self {
        return Self{
            .taskqueue = FutureFifo.init(),
            .taskmemory = [_]?TaskInterface{null} ** 32,
            .pending = 0,
            .allocator = allocator,
        };
    }

    fn spawn(self: *Self, comptime T: type, future: GFuture(T), joinhandle: ?*GJoinHandle(T)) !void {
        var taskid: ?usize = null;
        for (&self.taskmemory, 0..) |*taskopt, i| {
            if (taskopt.* == null) {
                const newtaskptr = try self.allocator.create(GTask(T));
                newtaskptr.* = GTask(T){
                    .id = i,
                    .future = future,
                    .joinhandle = joinhandle,
                    .executor = self,
                };
                taskopt.* = newtaskptr.task();
                taskid = i;
                break;
            }
        }
        if (taskid) |id| {
            try self.taskqueue.writeItem(id);
            self.pending += 1;
        } else {
            return ExecutorError.OutOfTaskMemory;
        }
    }

    fn wakeTask(self: *Self, taskid: usize) void {
        self.taskqueue.writeItem(taskid) catch unreachable;
    }

    fn run(self: *Self) !void {
        while (true) {
            const taskidopt = self.taskqueue.readItem();
            if (taskidopt) |taskid| {
                const taskopt = self.taskmemory[taskid];
                if (taskopt) |task| {
                    if (task.pollReady()) {
                        // Ready
                        self.taskmemory[taskid] = null;
                        // I need the ptr to be aligned and sized properly compiletime for the free to work!
                        const slicetofree: []u8 = @as([*]u8, @ptrCast(@alignCast(task.ptr)))[0..task.tasksize];
                        self.allocator.free(slicetofree);
                        self.pending -= 1;
                        if (self.pending == 0) return;
                    }
                } else {
                    return ExecutorError.UnknownTaskID;
                }
            }
        }
    }
};

const ExecutorError = error{
    OutOfTaskMemory,
    UnknownTaskID,
};

// Here a test Future to try the Executor
fn GWaitFuture(comptime T: type) type {
    return struct {
        out: T,
        seconds: u64,
        launched: bool = false,
        resultmutex: std.Thread.Mutex = std.Thread.Mutex{},
        result: ?T = null,

        const Self = @This();

        fn asyncthings(waker: Waker, res: *?T, resmutex: *std.Thread.Mutex, timesec: u64, out: T) void {
            std.time.sleep(timesec * 1000000000); // Seconds
            {
                resmutex.lock();
                defer resmutex.unlock();
                res.* = out;
            }
            waker.wake();
        }

        fn poll(ctx: *anyopaque, waker: Waker) GPoll(T) {
            var self: *Self = @ptrCast(@alignCast(ctx));
            if (!self.launched) {
                var thread = std.Thread.spawn(.{}, Self.asyncthings, .{
                    waker,
                    &self.result,
                    &self.resultmutex,
                    self.seconds,
                    self.out,
                }) catch unreachable;
                thread.detach();
                self.launched = true;
                return GPoll(T){ .pending = {} };
            }
            {
                self.resultmutex.lock();
                defer self.resultmutex.unlock();
                if (self.result) |r| {
                    return GPoll(T){ .ready = r };
                } else {
                    std.debug.print("Poll when not ready!\n", .{});
                    return GPoll(T){ .pending = {} };
                }
            }
        }

        fn future(self: *Self) GFuture(T) {
            return GFuture(T){
                .ptr = self,
                .pollfn = Self.poll,
            };
        }
    };
}

pub fn main() !void {
    var taskbuffer = [_]u8{0} ** 1024;
    var fba = FixedBufferAllocator.init(&taskbuffer);
    // The original implementor of Future NEED TO BE PINNED IN MEMORY
    // They need to be still in memory without move for all the length of the Executor Run
    // The same for JoinHandlers and Executor
    var jh1 = GJoinHandle(u16){};
    var jh3 = GJoinHandle(u64){};
    var fut1 = GWaitFuture(u16){ .out = 42, .seconds = 3 };
    var fut2 = GWaitFuture(u32){ .out = 16, .seconds = 1 };
    var fut3 = GWaitFuture(u64){ .out = 24, .seconds = 2 };
    var executor = GExecutor.init(fba.allocator());
    try executor.spawn(u16, fut1.future(), &jh1);
    try executor.spawn(u32, fut2.future(), null);
    try executor.spawn(u64, fut3.future(), &jh3);
    try executor.run();
    std.debug.print("Execution completed. Results:\n", .{});
    std.debug.print("Fut1 JoinHandle.result = {d}\n", .{jh1.result.?});
    std.debug.print("Fut3 JoinHandle.result = {d}\n", .{jh3.result.?});
}
