const std = @import("std");

// Zig 0.16 removed std.Thread.Mutex / std.Thread.Condition / std.Thread.ResetEvent
// (and std.Thread.sleep) in favor of the new std.Io-based primitives, which
// require threading an `io` handle through every call site. ResetEvent has been
// migrated to std.Io.Event (see its usages); this module still provides
// pthreads-backed drop-in replacements for Mutex and Condition (libC is always
// linked by this project).

extern "c" fn clock_gettime(clk_id: std.c.clockid_t, tp: *std.c.timespec) c_int;

fn deadlineFromNow(timeout_ns: u64) std.c.timespec {
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(std.c.CLOCK.REALTIME, &ts);

    const ns_per_s = std.time.ns_per_s;
    const total_nsec = @as(u64, @intCast(ts.nsec)) + (timeout_ns % ns_per_s);
    ts.sec += @intCast(timeout_ns / ns_per_s + total_nsec / ns_per_s);
    ts.nsec = @intCast(total_nsec % ns_per_s);
    return ts;
}

pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

pub const Condition = struct {
    inner: std.c.pthread_cond_t = .{},

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = std.c.pthread_cond_wait(&self.inner, &mutex.inner);
    }

    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const deadline = deadlineFromNow(timeout_ns);
        if (std.c.pthread_cond_timedwait(&self.inner, &mutex.inner, &deadline) == .TIMEDOUT) {
            return error.Timeout;
        }
    }

    pub fn signal(self: *Condition) void {
        _ = std.c.pthread_cond_signal(&self.inner);
    }

    pub fn broadcast(self: *Condition) void {
        _ = std.c.pthread_cond_broadcast(&self.inner);
    }
};
