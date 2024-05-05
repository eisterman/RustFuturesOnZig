const std = @import("std");
const fifo = std.fifo;
const Allocator = std.mem.Allocator;

// TODO Implement a Return Handler for the futures, to read the results
const Poll = union(enum) {
    pending: void,
    ready: u64,
};

// Future Interface
const Future = struct {
    ptr: *anyopaque,
    pollfn: *const fn (ctx: *anyopaque, waker: Waker) Poll,

    fn poll(self: *const Future, waker: Waker) Poll {
        return self.pollfn(self.ptr, waker);
    }
};

// TODO Split Waker into Waker (Interface) and our Executor Waker
//     similarly to Future
const Waker = struct {
    executorptr: *anyopaque,
    execwakefn: *const fn (ctx: *anyopaque, future: Future) void,
    future: Future,

    fn wake(self: *const Waker) void {
        self.execwakefn(self.executorptr, self.future);
    }
};

const JoinHandle = struct {
    //TODO Devo trovare un modo di tornare l'output di una task allo schedulatore originale
    //di essa. L'ideale e' un JoinHandle con una variabile (non serve il Mutex perche siamo
    //in single-thread) che l'Executor vada a scrivere. Il JoinHandle e' anche lui Pin.
    //La vera domanda e' come collegare il Future al Handle dato che al momento manca la
    //struttura delle Task all'interno del Executor ma uso i Future direttamente.
    //L'unico modo sarebbe creare un oggetto Task che contenga Future e *JoinHandle.
    //Il waker deve poter quindi ricreare l'intero oggetto.
    //Ovvero basta togliere Waker.future e sostituirlo con Waker.task!
    //Dovrebbe essere tutto abbastanza straightforward.
};

const Executor = struct {
    const FutureFifo = fifo.LinearFifo(Future, fifo.LinearFifoBufferType{ .Static = 32 });

    taskqueue: FutureFifo,
    wakedqueue: FutureFifo,

    fn init() Executor {
        return Executor{
            .taskqueue = FutureFifo.init(),
            .wakedqueue = FutureFifo.init(),
        };
    }

    fn spawn(self: *Executor, future: Future) !void {
        try self.taskqueue.writeItem(future);
    }

    fn wakefuture(ctx: *anyopaque, future: Future) void {
        var self: *Executor = @ptrCast(@alignCast(ctx));
        self.wakedqueue.writeItem(future) catch unreachable;
    }

    fn pollFuture(self: *Executor, future: Future) Poll {
        const waker = Waker{
            .executorptr = self,
            .execwakefn = Executor.wakefuture,
            .future = future,
        };
        const poll = future.poll(waker);
        return poll;
    }

    fn run(self: *Executor) !void {
        while (true) {
            const futopt: ?Future = futopt: {
                const priot = self.wakedqueue.readItem();
                if (priot) |_| {
                    break :futopt priot;
                }
                const norm = self.taskqueue.readItem();
                break :futopt norm;
            };
            if (futopt) |fut| {
                switch (self.pollFuture(fut)) {
                    Poll.ready => |val| {
                        // TODO how to remove task from taskqueue when
                        //   the Ready has come from a Wake->Prioqueue poll?
                        //   We dont! We replace Future queue with Task queue!
                        // Do something with the result?
                        std.debug.print("Ready: {d}\n", .{val});
                    },
                    Poll.pending => {
                        try self.taskqueue.writeItem(fut);
                    },
                }
            } else {
                return; // Stop when no task queued
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
    var fut1 = WaitFuture{ .out = 42, .seconds = 3 };
    var fut2 = WaitFuture{ .out = 16, .seconds = 1 };
    var fut3 = WaitFuture{ .out = 24, .seconds = 2 };
    var executor = Executor.init();
    try executor.spawn(fut1.future());
    try executor.spawn(fut2.future());
    try executor.spawn(fut3.future());
    try executor.run();
    std.debug.print("Execution completed\n", .{});
}
