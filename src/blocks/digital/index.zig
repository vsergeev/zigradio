// Pull in all tests
test {
    @import("std").testing.refAllDecls(@This());
}

pub const DifferentialDecoderBlock = @import("differentialdecoder.zig").DifferentialDecoderBlock;
