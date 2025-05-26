// Pull in all tests
test {
    @import("std").testing.refAllDecls(@This());
}

pub const DifferentialDecoderBlock = @import("differentialdecoder.zig").DifferentialDecoderBlock;
pub const SlicerBlock = @import("slicer.zig").SlicerBlock;
pub const BinarySlicer = @import("slicer.zig").BinarySlicer;
