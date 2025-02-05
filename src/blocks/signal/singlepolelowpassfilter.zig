const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const _IIRFilterBlock = @import("./iirfilter.zig")._IIRFilterBlock;

////////////////////////////////////////////////////////////////////////////////
// Singlepole Lowpass Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn SinglepoleLowpassFilterBlock(comptime T: type) type {
    return _IIRFilterBlock(T, 2, 2, struct {
        cutoff: f32,

        pub fn init(cutoff: f32) SinglepoleLowpassFilterBlock(T) {
            return SinglepoleLowpassFilterBlock(T)._init(.{ .cutoff = cutoff });
        }

        pub fn initialize(self: *SinglepoleLowpassFilterBlock(T), _: std.mem.Allocator) !void {
            // Compute wraped tau
            const rate = self.block.getRate(f32);
            const tau = 1 / (2 * rate * std.math.tan((std.math.pi * self.context.cutoff) / rate));

            // Populate taps
            self.b_taps[0] = 1 / (1 + 2 * tau * rate);
            self.b_taps[1] = 1 / (1 + 2 * tau * rate);
            self.a_taps[0] = 1;
            self.a_taps[1] = (1 - 2 * tau * rate) / (1 + 2 * tau * rate);
        }
    });
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/singlepolelowpassfilter.zig");

test "SinglepoleLowpassFilterBlock" {
    // 1e-2 cutoff, ComplexFloat32
    {
        var block = SinglepoleLowpassFilterBlock(std.math.Complex(f32)).init(0.01);
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_cutoff_0_01_complexfloat32});
    }

    // 1e-2 cutoff, Float32
    {
        var block = SinglepoleLowpassFilterBlock(f32).init(0.01);
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{f32}, .{&vectors.input_float32}, &[1]type{f32}, .{&vectors.output_cutoff_0_01_float32});
    }
}
