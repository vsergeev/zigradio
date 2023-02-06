// Pull in all tests
test {
    @import("std").testing.refAllDecls(@This());
}

pub const DownsamplerBlock = @import("downsampler.zig").DownsamplerBlock;
