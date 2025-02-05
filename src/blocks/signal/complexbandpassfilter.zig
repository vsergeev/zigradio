const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const _FIRFilterBlock = @import("./firfilter.zig")._FIRFilterBlock;

const WindowFunction = @import("../../radio.zig").utils.window.WindowFunction;
const firwinComplexBandpass = @import("../../radio.zig").utils.filter.firwinComplexBandpass;

////////////////////////////////////////////////////////////////////////////////
// Complex Bandpass Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn ComplexBandpassFilterBlock(comptime N: comptime_int) type {
    return _FIRFilterBlock(std.math.Complex(f32), std.math.Complex(f32), N, struct {
        pub const Options = struct {
            nyquist: ?f32 = null,
            window: WindowFunction = WindowFunction.Hamming,
        };

        cutoffs: struct { f32, f32 },
        options: Options,

        pub fn init(cutoffs: struct { f32, f32 }, options: Options) ComplexBandpassFilterBlock(N) {
            return ComplexBandpassFilterBlock(N)._init(.{ .cutoffs = cutoffs, .options = options });
        }

        pub fn initialize(self: *ComplexBandpassFilterBlock(N), _: std.mem.Allocator) !void {
            // Compute Nyquist frequency
            const nyquist = self.context.options.nyquist orelse (self.block.getRate(f32) / 2);

            // Generate taps
            self.taps = firwinComplexBandpass(N, .{ self.context.cutoffs[0] / nyquist, self.context.cutoffs[1] / nyquist }, self.context.options.window);
        }
    });
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/complexbandpassfilter.zig");

test "ComplexBandpassFilterBlock" {
    // 129 taps, [0.1, 0.3] cutoffs
    {
        var block = ComplexBandpassFilterBlock(129).init(.{ 0.1, 0.3 }, .{});
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_taps_129_cutoff_0_1_0_3});
    }

    // 129 taps, [-0.1, -0.3] cutoffs
    {
        var block = ComplexBandpassFilterBlock(129).init(.{ -0.1, -0.3 }, .{});
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_taps_129_cutoff_m0_1_m0_3});
    }

    // 129 taps, [-0.2, 0.2] cutoffs
    {
        var block = ComplexBandpassFilterBlock(129).init(.{ -0.2, 0.2 }, .{});
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_taps_129_cutoff_m0_2_p0_2});
    }

    // 129 taps, [0.4, 0.6] cutoffs, 3.0 nyquist, Bartlett window
    {
        var block = ComplexBandpassFilterBlock(129).init(.{ 0.4, 0.6 }, .{ .nyquist = 3.0, .window = WindowFunction.Bartlett });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_taps_129_cutoff_0_4_0_6_nyquist_3_0_window_bartlett});
    }
}
