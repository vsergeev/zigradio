const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const _IIRFilterBlock = @import("./iirfilter.zig")._IIRFilterBlock;

////////////////////////////////////////////////////////////////////////////////
// Singlepole Highpass Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn SinglepoleHighpassFilterBlock(comptime T: type) type {
    return _IIRFilterBlock(T, 2, 2, struct {
        cutoff: f32,

        pub fn init(cutoff: f32) SinglepoleHighpassFilterBlock(T) {
            return SinglepoleHighpassFilterBlock(T)._init(.{ .cutoff = cutoff });
        }

        pub fn initialize(self: *SinglepoleHighpassFilterBlock(T), _: std.mem.Allocator) !void {
            // Compute wraped tau
            const rate = self.block.getRate(f32);
            const tau = 1 / (2 * rate * std.math.tan((std.math.pi * self.context.cutoff) / rate));

            // Populate taps
            self.b_taps[0] = (2 * tau * rate) / (1 + 2 * tau * rate);
            self.b_taps[1] = -(2 * tau * rate) / (1 + 2 * tau * rate);
            self.a_taps[0] = 1;
            self.a_taps[1] = (1 - 2 * tau * rate) / (1 + 2 * tau * rate);
        }
    });
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/singlepolehighpassfilter.zig");

test "SinglepoleHighpassFilterBlock" {
    // 1e-2 cutoff, ComplexFloat32
    {
        var block = SinglepoleHighpassFilterBlock(std.math.Complex(f32)).init(0.01);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_cutoff_0_01_complexfloat32});
    }

    // 1e-2 cutoff, Float32
    {
        var block = SinglepoleHighpassFilterBlock(f32).init(0.01);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_cutoff_0_01_float32});
    }
}
