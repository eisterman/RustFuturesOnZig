const std = @import("std");
const fifo = std.fifo;
const Allocator = std.mem.Allocator;

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

// TODO Split Waker into Waker (Interface) and our Executor Waker
//     similarly to Future
const Waker = struct {
    executorptr: *anyopaque,
    execwakefn: *const fn (ctx: *anyopaque, task: Task) void,
    task: Task,

    fn wake(self: *const Waker) void {
        self.execwakefn(self.executorptr, self.task);
    }
};

const JoinHandle = struct {
    result: ?u64 = null,
};

const Task = struct {
    future: Future,
    joinhandle: ?*JoinHandle,
};

const Executor = struct {
    const FutureFifo = fifo.LinearFifo(Task, fifo.LinearFifoBufferType{ .Static = 32 });

    taskqueue: FutureFifo,
    pending: u64,

    fn init() Executor {
        return Executor{
            .taskqueue = FutureFifo.init(),
            .pending = 0,
        };
    }

    fn spawn(self: *Executor, future: Future, joinhandle: ?*JoinHandle) !void {
        const task = Task{
            .future = future,
            .joinhandle = joinhandle,
        };
        try self.taskqueue.writeItem(task);
        self.pending += 1;
    }

    fn wakeTask(ctx: *anyopaque, task: Task) void {
        var self: *Executor = @ptrCast(@alignCast(ctx));
        self.taskqueue.writeItem(task) catch unreachable;
    }

    fn pollTask(self: *Executor, task: Task) Poll {
        const waker = Waker{
            .executorptr = self,
            .execwakefn = Executor.wakeTask,
            .task = task,
        };
        const poll = task.future.poll(waker);
        return poll;
    }

    fn run(self: *Executor) !void {
        while (true) {
            const taskopt = self.taskqueue.readItem();
            if (taskopt) |task| {
                switch (self.pollTask(task)) {
                    Poll.ready => |val| {
                        // Do something with the result
                        std.debug.print("Ready: {d}\n", .{val});
                        if (task.joinhandle) |jh| {
                            jh.result = val;
                        }
                        self.pending -= 1;
                        if (self.pending == 0) {
                            return;
                        }
                    },
                    Poll.pending => {},
                }
            }
        }
    }
};

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
    // The same for JoinHandlers if needed
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
