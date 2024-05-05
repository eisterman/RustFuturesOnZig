const std = @import("std");
const fifo = std.fifo;
const Allocator = std.mem.Allocator;

const Poll = union(enum) {
    pending: void,
    ready: u64,
};

fn asyncthings(waker: *const Waker, timesec: u64) void {
    std.time.sleep(timesec * 1000000000); // Seconds
    waker.wake();
}

const Future = struct {
    out: u64,
    seconds: u64,
    polled: bool = false,

    fn pool(self: *Future, waker: *const Waker) Poll {
        switch (self.polled) {
            false => {
                var thread = std.Thread.spawn(.{}, asyncthings, .{ waker, self.seconds }) catch unreachable;
                thread.detach();
                self.polled = true;
                return Poll{ .pending = {} };
            },
            true => {
                return Poll{ .ready = self.out };
            },
        }
    }
};

const Waker = struct {
    executor: *Executor,
    task: *?Task,

    fn wake(self: *const Waker) void {
        self.executor.schedule(self.task) catch unreachable;
    }
};

const Task = struct {
    future: *Future,
    waker: Waker,
};

const ExecutorFifoType = fifo.LinearFifo(*?Task, fifo.LinearFifoBufferType{ .Static = 32 });

const Executor = struct {
    taskqueue: ExecutorFifoType,
    taskmemory: [20]?Task,
    pending: u64 = 0,

    fn init() Executor {
        const queue = ExecutorFifoType.init();
        return Executor{
            .taskqueue = queue,
            .taskmemory = [_]?Task{null} ** 20,
        };
    }

    fn spawn(self: *Executor, future: *Future) !void {
        var setted = false;
        for (&self.taskmemory) |*t| {
            if (t.* == null) {
                const waker = Waker{ .executor = self, .task = @ptrCast(t) };
                t.* = Task{ .waker = waker, .future = future };
                setted = true;
                try self.taskqueue.writeItem(t);
                self.pending += 1;
                break;
            }
        }
        if (setted == false) {
            unreachable;
        }
    }

    fn schedule(self: *Executor, task: *?Task) !void {
        try self.taskqueue.writeItem(task);
    }

    fn run(self: *Executor) !void {
        while (true) {
            const taskopt = self.taskqueue.readItem();
            if (taskopt) |task| {
                const res = task.*.?.future.pool(&task.*.?.waker);
                switch (res) {
                    Poll.ready => |val| {
                        std.debug.print("Ready: {d}\n", .{val});
                        self.pending -= 1;
                        task.* = null;
                        if (self.pending == 0) return;
                    },
                    Poll.pending => {},
                }
            }
        }
    }

    fn deinit(self: *Executor) void {
        self.taskqueue.deinit();
    }
};

pub fn main() !void {
    var fut1 = Future{ .out = 42, .seconds = 3 };
    var fut2 = Future{ .out = 16, .seconds = 2 };
    var fut3 = Future{ .out = 24, .seconds = 1 };
    var executor = Executor.init();
    try executor.spawn(&fut1);
    try executor.spawn(&fut2);
    try executor.spawn(&fut3);
    try executor.run();
    std.debug.print("Execution completed\n", .{});
}
