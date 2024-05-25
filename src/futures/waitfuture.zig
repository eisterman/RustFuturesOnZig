const std = @import("std");
const tasklib = @import("../task.zig");
const Poll = tasklib.Poll;
const Future = tasklib.Future;
const Waker = tasklib.Waker;

pub fn WaitFuture(comptime T: type) type {
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

        fn poll(ctx: *anyopaque, waker: Waker) Poll(T) {
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
                return Poll(T){ .pending = {} };
            }
            {
                self.resultmutex.lock();
                defer self.resultmutex.unlock();
                if (self.result) |r| {
                    return Poll(T){ .ready = r };
                } else {
                    std.debug.print("Poll when not ready!\n", .{});
                    return Poll(T){ .pending = {} };
                }
            }
        }

        pub fn future(self: *Self) Future(T) {
            return Future(T){
                .ptr = self,
                .pollfn = Self.poll,
            };
        }
    };
}
