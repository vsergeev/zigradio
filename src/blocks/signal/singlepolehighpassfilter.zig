// @block SinglepoleHighpassFilterBlock
// @description Filter a complex or real valued signal with a single-pole
// high-pass IIR filter.
//
// $$ H(s) = \frac{\tau s}{\tau s + 1} $$
//
// $$ H(z) = \frac{2\tau f_s}{1 + 2\tau f_s} \frac{1 - z^{-1}}{1 + (\frac{1 - 2\tau f_s}{1 + 2\tau f_s}) z^{-1}} $$
//
// $$ y[n] = \frac{2\tau f_s}{1 + 2\tau f_s} \; x[n] + \frac{2\tau f_s}{1 + 2\tau f_s} \; x[n-1] - \frac{1 - 2\tau f_s}{1 + 2\tau f_s} \; y[n-1] $$
//
// @category Filtering
// @ctparam T type Complex(f32), f32
// @param cutoff f32 Cutoff frequency in Hz
// @signature in1:T > out1:T
// @usage
// var filter = radio.blocks.SinglepoleHighpassFilterBlock(f32).init(100);

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const IIRFilter = @import("./iirfilter.zig").IIRFilter;

////////////////////////////////////////////////////////////////////////////////
// Singlepole Highpass Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn SinglepoleHighpassFilterBlock(comptime T: type) type {
    return struct {
        const Self = @This();

        block: Block,
        cutoff: f32,
        filter: IIRFilter(T, 2, 2),

        pub fn init(cutoff: f32) Self {
            return .{ .block = Block.init(@This()), .cutoff = cutoff, .filter = IIRFilter(T, 2, 2).init() };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            // Compute warped tau
            const rate = self.block.getRate(f32);
            const tau = 1 / (2 * rate * std.math.tan((std.math.pi * self.cutoff) / rate));

            // Populate taps
            self.filter.b_taps[0] = (2 * tau * rate) / (1 + 2 * tau * rate);
            self.filter.b_taps[1] = -(2 * tau * rate) / (1 + 2 * tau * rate);
            self.filter.a_taps[0] = 1;
            self.filter.a_taps[1] = (1 - 2 * tau * rate) / (1 + 2 * tau * rate);

            // Initialize filter
            return self.filter.initialize(allocator);
        }

        pub fn deinitialize(self: *Self, allocator: std.mem.Allocator) void {
            self.filter.deinitialize(allocator);
        }

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            return self.filter.process(x, y);
        }
    };
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
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_cutoff_0_01_complexfloat32}, .{});
    }

    // 1e-2 cutoff, Float32
    {
        var block = SinglepoleHighpassFilterBlock(f32).init(0.01);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_cutoff_0_01_float32}, .{});
    }
}
