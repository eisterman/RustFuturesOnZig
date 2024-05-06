const std = @import("std");
const fifo = std.fifo;
const Allocator = std.mem.Allocator;

// TODO generalize for Future return types!
//      Very complex stuff!
const Poll = union(enum) {
    pending: void,
    ready: u64,
};

// Future Interface
const Future = struct {
    ptr: *anyopaque,
    pollfn: *const fn (ctx: *anyopaque, waker: Waker) Poll,

    // Poll is called 1 time to start the future and then
    // it will be polled again only when Waker is called
    fn poll(self: *const Future, waker: Waker) Poll {
        return self.pollfn(self.ptr, waker);
    }
};

// Waker Interface
const Waker = struct {
    ptr: *anyopaque,
    wakefn: *const fn (ctx: *anyopaque) void,

    fn wake(self: *const Waker) void {
        self.wakefn(self.ptr);
    }
};

// Here a Executor implementation for this interface

const JoinHandle = struct {
    result: ?u64 = null,
};

const Task = struct {
    id: usize,
    future: Future,
    joinhandle: ?*JoinHandle,
    executor: *Executor,

    fn getWaker(self: *Task) Waker {
        return Waker{
            .wakefn = Task.wake,
            .ptr = @constCast(self),
        };
    }

    fn poll(self: *Task) Poll {
        return self.future.poll(self.getWaker());
    }

    fn wake(ctx: *anyopaque) void {
        const self: *Task = @ptrCast(@alignCast(ctx));
        self.executor.wakeTask(self.id);
    }
};

const ExecutorError = error{
    OutOfTaskMemory,
    UnknownTaskID,
};

const Executor = struct {
    const FutureFifo = fifo.LinearFifo(usize, fifo.LinearFifoBufferType{ .Static = 32 });

    taskqueue: FutureFifo,
    taskmemory: [32]?Task,
    pending: u64,

    fn init() Executor {
        return Executor{
            .taskqueue = FutureFifo.init(),
            .taskmemory = [_]?Task{null} ** 32,
            .pending = 0,
        };
    }

    fn spawn(self: *Executor, future: Future, joinhandle: ?*JoinHandle) !void {
        var taskid: ?usize = null;
        for (&self.taskmemory, 0..) |*taskopt, i| {
            if (taskopt.* == null) {
                taskopt.* = Task{
                    .id = i,
                    .future = future,
                    .joinhandle = joinhandle,
                    .executor = self,
                };
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

    fn wakeTask(self: *Executor, taskid: usize) void {
        self.taskqueue.writeItem(taskid) catch unreachable;
    }

    fn run(self: *Executor) !void {
        while (true) {
            const taskidopt = self.taskqueue.readItem();
            if (taskidopt) |taskid| {
                const taskptr = &self.taskmemory[taskid];
                // In general Capture syntax is possibly a Copy so they are to NOT use when the address of self is important!
                // It's better to spam .*.? because in Release the .? become nop and we don't risk dangling ptrs.
                if (taskptr.* != null) {
                    switch (taskptr.*.?.poll()) {
                        Poll.ready => |val| {
                            const taskval = taskptr.*.?; // From here the ptr is not important
                            std.debug.print("Ready Task {d}: {d}\n", .{ taskval.id, val });
                            if (taskval.joinhandle) |jh| {
                                jh.result = val;
                            }
                            taskptr.* = null;
                            self.pending -= 1;
                            if (self.pending == 0) {
                                return;
                            }
                        },
                        Poll.pending => {},
                    }
                } else {
                    return ExecutorError.UnknownTaskID;
                }
            }
        }
    }
};

// Here a test Future to try the Executor

fn asyncthings(waker: Waker, res: *?u64, resmutex: *std.Thread.Mutex, timesec: u64, out: u64) void {
    std.time.sleep(timesec * 1000000000); // Seconds
    {
        resmutex.lock();
        defer resmutex.unlock();
        res.* = out;
    }
    waker.wake();
}

const WaitFuture = struct {
    out: u64,
    seconds: u64,
    launched: bool = false,
    resultmutex: std.Thread.Mutex = std.Thread.Mutex{},
    result: ?u64 = null,

    fn poll(ctx: *anyopaque, waker: Waker) Poll {
        var self: *WaitFuture = @ptrCast(@alignCast(ctx));
        if (!self.launched) {
            var thread = std.Thread.spawn(.{}, asyncthings, .{
                waker,
                &self.result,
                &self.resultmutex,
                self.seconds,
                self.out,
            }) catch unreachable;
            thread.detach();
            self.launched = true;
            return Poll{ .pending = {} };
        }
        {
            self.resultmutex.lock();
            defer self.resultmutex.unlock();
            if (self.result) |r| {
                return Poll{ .ready = r };
            } else {
                return Poll{ .pending = {} };
            }
        }
    }

    fn future(self: *WaitFuture) Future {
        return Future{
            .ptr = self,
            .pollfn = WaitFuture.poll,
        };
    }
};

pub fn main() !void {
    // The original implementor of Future NEED TO BE PINNED IN MEMORY
    // They need to be still in memory without move for all the length of the Executor Run
    // The same for JoinHandlers and Executor
    var jh1 = JoinHandle{};
    var jh3 = JoinHandle{};
    var fut1 = WaitFuture{ .out = 42, .seconds = 3 };
    var fut2 = WaitFuture{ .out = 16, .seconds = 1 };
    var fut3 = WaitFuture{ .out = 24, .seconds = 2 };
    var executor = Executor.init();
    try executor.spawn(fut1.future(), &jh1);
    try executor.spawn(fut2.future(), null);
    try executor.spawn(fut3.future(), &jh3);
    try executor.run();
    std.debug.print("Execution completed. Results:\n", .{});
    std.debug.print("Fut1 JoinHandle.result = {d}\n", .{jh1.result.?});
    std.debug.print("Fut3 JoinHandle.result = {d}\n", .{jh3.result.?});
}
