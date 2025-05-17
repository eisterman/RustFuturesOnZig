const std = @import("std");
const tasklib = @import("../task.zig");
const Poll = tasklib.Poll;
const Future = tasklib.Future;
const Waker = tasklib.Waker;

pub const ReadyFuture = struct {
    const Self = @This();
    fn poll(ctx: *anyopaque, waker: Waker) Poll(void) {
        _ = &ctx;
        _ = &waker;
        return Poll(void){ .ready = {} };
    }

    pub fn future(self: *Self) Future(void) {
        return Future(void){
            .ptr = self,
            .pollfn = Self.poll,
        };
    }
};
