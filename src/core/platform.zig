const std = @import("std");

////////////////////////////////////////////////////////////////////////////////
// Platform Functions
////////////////////////////////////////////////////////////////////////////////

pub fn waitForInterrupt() void {
    var mask = std.posix.empty_sigset;
    var signal: c_int = undefined;
    std.os.linux.sigaddset(&mask, std.posix.SIG.INT);
    _ = std.c.sigprocmask(std.posix.SIG.BLOCK, &mask, null);
    _ = std.c.sigwait(&mask, &signal);
}
