const std = @import("std");
const rfuture = @import("rfutures");
const fifo = std.fifo;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const JoinHandle = rfuture.executor.JoinHandle;
const ReadyFuture = rfuture.futures.ReadyFuture;
const Executor = rfuture.executor.Executor;

pub fn main() !void {
    var taskbuffer = [_]u8{0} ** 1024;
    var fba = FixedBufferAllocator.init(&taskbuffer);

    var fut = ReadyFuture{};
    var executor = Executor.init(fba.allocator());
    try executor.spawn(void, fut.future(), null);
    std.debug.print("Execution completed.\n", .{});
}
