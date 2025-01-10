const std = @import("std");

////////////////////////////////////////////////////////////////////////////////
// Platform Features
////////////////////////////////////////////////////////////////////////////////

pub var libs: struct {
    liquid: ?std.DynLib,
    volk: ?std.DynLib,
    fftw3f: ?std.DynLib,
} = .{
    .liquid = null,
    .volk = null,
    .fftw3f = null,
};

pub var debug: struct {
    enabled: bool,
} = .{
    .enabled = false,
};

fn isTruthy(value: []const u8) bool {
    const haystack = [_][]const u8{ "1", "true", "TRUE", "yes", "YES" };
    for (haystack) |x| {
        if (std.mem.eql(u8, value, x)) return true;
    }
    return false;
}

fn lookupEnvFlag(allocator: std.mem.Allocator, key: []const u8) !bool {
    if (std.process.getEnvVarOwned(allocator, key)) |env_var| {
        defer allocator.free(env_var);
        return isTruthy(env_var);
    } else |_| {
        return false;
    }
}

pub fn initialize(allocator: std.mem.Allocator) !void {
    debug.enabled = try lookupEnvFlag(allocator, "ZIGRADIO_DEBUG");

    if (libs.liquid == null and !try lookupEnvFlag(allocator, "ZIGRADIO_DISABLE_LIQUID")) {
        libs.liquid = std.DynLib.open("libliquid.so") catch null;
    }
    if (libs.volk == null and !try lookupEnvFlag(allocator, "ZIGRADIO_DISABLE_VOLK")) {
        libs.volk = std.DynLib.open("libvolk.so") catch null;
    }
    if (libs.fftw3f == null and !try lookupEnvFlag(allocator, "ZIGRADIO_DISABLE_FFTW3F")) {
        libs.fftw3f = std.DynLib.open("libfftw3f.so") catch null;
    }
}

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
