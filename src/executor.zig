const std = @import("std");
const fifo = std.fifo;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const tasklib = @import("task.zig");
const Waker = tasklib.Waker;
const Future = tasklib.Future;
const Poll = tasklib.Poll;

pub fn JoinHandle(comptime T: type) type {
    return struct {
        result: ?T = null,
    };
}

const TaskVTable = struct {
    pollReady: *const fn (ctx: *anyopaque) bool,
    getId: *const fn (ctx: *anyopaque) usize,
};

const Task = struct {
    ptr: *anyopaque,
    size: usize,
    vtable: TaskVTable,

    const Self = @This();

    fn pollReady(self: Self) bool {
        return self.vtable.pollReady(self.ptr);
    }

    fn getId(self: Self) usize {
        return self.vtable.getId(self.ptr);
    }
};

fn TypeTask(comptime T: type) type {
    return struct {
        id: usize,
        future: Future(T),
        joinhandle: ?*JoinHandle(T),
        executor: *Executor,

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
                Poll(T).pending => return false,
                Poll(T).ready => |val| {
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

        fn task(self: *Self) Task {
            return Task{
                .ptr = self,
                .size = @sizeOf(Self),
                .vtable = TaskVTable{
                    .getId = Self.getId,
                    .pollReady = Self.pollReady,
                },
            };
        }
    };
}

pub const Executor = struct {
    const FutureFifo = fifo.LinearFifo(usize, fifo.LinearFifoBufferType{ .Static = 32 });

    taskqueue: FutureFifo,
    taskmemory: [32]?Task,
    pending: u64,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .taskqueue = FutureFifo.init(),
            .taskmemory = [_]?Task{null} ** 32,
            .pending = 0,
            .allocator = allocator,
        };
    }

    pub fn spawn(self: *Self, comptime T: type, future: Future(T), joinhandle: ?*JoinHandle(T)) !void {
        var taskid: ?usize = null;
        for (&self.taskmemory, 0..) |*taskopt, i| {
            if (taskopt.* == null) {
                const newtaskptr = try self.allocator.create(TypeTask(T));
                newtaskptr.* = TypeTask(T){
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

    pub fn wakeTask(self: *Self, taskid: usize) void {
        self.taskqueue.writeItem(taskid) catch unreachable;
    }

    pub fn run(self: *Self) !void {
        while (true) {
            const taskidopt = self.taskqueue.readItem();
            if (taskidopt) |taskid| {
                const taskopt = self.taskmemory[taskid];
                if (taskopt) |task| {
                    if (task.pollReady()) {
                        // Ready
                        self.taskmemory[taskid] = null;
                        // I need the ptr to be aligned and sized properly compiletime for the free to work!
                        const slicetofree: []u8 = @as([*]u8, @ptrCast(@alignCast(task.ptr)))[0..task.size];
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

pub const ExecutorError = error{
    OutOfTaskMemory,
    UnknownTaskID,
};
