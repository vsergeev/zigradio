// Pull in all tests
test {
    @import("std").testing.refAllDecls(@This());
}

pub const math = @import("./math.zig");
pub const window = @import("./window.zig");
