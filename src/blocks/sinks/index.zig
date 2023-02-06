// Pull in all tests
test {
    @import("std").testing.refAllDecls(@This());
}

pub const PrintSink = @import("print.zig").PrintSink;
