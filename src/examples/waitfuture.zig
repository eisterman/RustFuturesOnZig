const std = @import("std");
const rfuture = @import("rfutures");
const fifo = std.fifo;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const JoinHandle = rfuture.executor.JoinHandle;
const WaitFuture = rfuture.futures.WaitFuture;
const Executor = rfuture.executor.Executor;

pub fn main() !void {
    var taskbuffer = [_]u8{0} ** 1024;
    var fba = FixedBufferAllocator.init(&taskbuffer);
    // The original implementor of Future NEED TO BE PINNED IN MEMORY
    // They need to be still in memory without move for all the length of the Executor Run
    // The same for JoinHandlers and Executor
    var jh1 = JoinHandle(u16){};
    var jh3 = JoinHandle(u64){};
    var fut1 = WaitFuture(u16){ .out = 42, .seconds = 3 };
    var fut2 = WaitFuture(u32){ .out = 16, .seconds = 1 };
    var fut3 = WaitFuture(u64){ .out = 24, .seconds = 2 };
    var executor = Executor.init(fba.allocator());
    try executor.spawn(u16, fut1.future(), &jh1);
    try executor.spawn(u32, fut2.future(), null);
    try executor.spawn(u64, fut3.future(), &jh3);
    try executor.run();
    std.debug.print("Execution completed. Results:\n", .{});
    std.debug.print("Fut1 JoinHandle.result = {d}\n", .{jh1.result.?});
    std.debug.print("Fut3 JoinHandle.result = {d}\n", .{jh3.result.?});
}
