const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const _FIRFilterBlock = @import("./firfilter.zig")._FIRFilterBlock;

const WindowFunction = @import("../../radio.zig").utils.window.WindowFunction;
const firwinBandstop = @import("../../radio.zig").utils.filter.firwinBandstop;

////////////////////////////////////////////////////////////////////////////////
// Bandstop Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn BandstopFilterBlock(comptime T: type, comptime N: comptime_int) type {
    return _FIRFilterBlock(T, f32, N, struct {
        pub const Options = struct {
            nyquist: ?f32 = null,
            window: WindowFunction = WindowFunction.Hamming,
        };

        cutoffs: struct { f32, f32 },
        options: Options,

        pub fn init(cutoffs: struct { f32, f32 }, options: Options) BandstopFilterBlock(T, N) {
            return BandstopFilterBlock(T, N)._init(.{ .cutoffs = cutoffs, .options = options });
        }

        pub fn initialize(self: *BandstopFilterBlock(T, N), _: std.mem.Allocator) !void {
            // Compute Nyquist frequency
            const nyquist = self.context.options.nyquist orelse (self.block.getRate(f32) / 2);

            // Generate taps
            self.taps = firwinBandstop(N, .{ self.context.cutoffs[0] / nyquist, self.context.cutoffs[1] / nyquist }, self.context.options.window);
        }
    });
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/bandstopfilter.zig");

test "BandstopFilterBlock" {
    // 129 taps, [0.1, 0.3] cutoffs, ComplexFloat32
    {
        var block = BandstopFilterBlock(std.math.Complex(f32), 129).init(.{ 0.1, 0.3 }, .{});
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_taps_129_cutoff_0_1_0_3_complexfloat32});
    }

    // 129 taps, [0.4, 0.6] cutoffs, 3.0 nyquist, Bartlett window, ComplexFloat32
    {
        var block = BandstopFilterBlock(std.math.Complex(f32), 129).init(.{ 0.4, 0.6 }, .{ .nyquist = 3.0, .window = WindowFunction.Bartlett });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_taps_129_cutoff_0_4_0_6_nyquist_3_0_window_bartlett_complexfloat32});
    }

    // 129 taps, [0.1, 0.3] cutoffs, Float32
    {
        var block = BandstopFilterBlock(f32, 129).init(.{ 0.1, 0.3 }, .{});
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{f32}, .{&vectors.input_float32}, &[1]type{f32}, .{&vectors.output_taps_129_cutoff_0_1_0_3_float32});
    }

    // 129 taps, [0.4, 0.6] cutoffs, 3.0 nyquist, Bartlett window, Float32
    {
        var block = BandstopFilterBlock(f32, 129).init(.{ 0.4, 0.6 }, .{ .nyquist = 3.0, .window = WindowFunction.Bartlett });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{f32}, .{&vectors.input_float32}, &[1]type{f32}, .{&vectors.output_taps_129_cutoff_0_4_0_6_nyquist_3_0_window_bartlett_float32});
    }
}
