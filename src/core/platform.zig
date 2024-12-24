const std = @import("std");
const platform_options = @import("platform_options");

////////////////////////////////////////////////////////////////////////////////
// Platform Functions
////////////////////////////////////////////////////////////////////////////////

pub fn hasPackage(comptime name: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    for (platform_options.packages) |pkg| {
        if (std.mem.eql(u8, pkg, name)) return true;
    }
    return false;
}

pub fn waitForInterrupt() void {
    var mask = std.posix.empty_sigset;
    var signal: c_int = undefined;
    std.os.linux.sigaddset(&mask, std.posix.SIG.INT);
    _ = std.c.sigprocmask(std.posix.SIG.BLOCK, &mask, null);
    _ = std.c.sigwait(&mask, &signal);
}
