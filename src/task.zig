pub fn Poll(comptime T: type) type {
    return union(enum) {
        pending: void,
        ready: T,
    };
}

pub const Waker = struct {
    ptr: *anyopaque,
    wakefn: *const fn (ctx: *anyopaque) void,

    pub fn wake(self: *const Waker) void {
        self.wakefn(self.ptr);
    }
};

pub fn Future(comptime T: type) type {
    return struct {
        ptr: *anyopaque,
        pollfn: *const fn (ctx: *anyopaque, waker: Waker) Poll(T),

        pub fn poll(self: *const @This(), waker: Waker) Poll(T) {
            return self.pollfn(self.ptr, waker);
        }
    };
}
