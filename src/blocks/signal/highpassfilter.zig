const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const _FIRFilterBlock = @import("./firfilter.zig")._FIRFilterBlock;

const WindowFunction = @import("../../radio.zig").utils.window.WindowFunction;
const firwinHighpass = @import("../../radio.zig").utils.filter.firwinHighpass;

////////////////////////////////////////////////////////////////////////////////
// Highpass Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn HighpassFilterBlock(comptime T: type, comptime N: comptime_int) type {
    return _FIRFilterBlock(T, f32, N, struct {
        pub const Options = struct {
            nyquist: ?f32 = null,
            window: WindowFunction = WindowFunction.Hamming,
        };

        cutoff: f32,
        options: Options,

        pub fn init(cutoff: f32, options: Options) HighpassFilterBlock(T, N) {
            return HighpassFilterBlock(T, N)._init(.{ .cutoff = cutoff, .options = options });
        }

        pub fn initialize(self: *HighpassFilterBlock(T, N), _: std.mem.Allocator) !void {
            // Compute Nyquist frequency
            const nyquist = self.context.options.nyquist orelse try self.block.getRate(f32) / 2;

            // Generate taps
            self.taps = firwinHighpass(N, self.context.cutoff / nyquist, self.context.options.window);
        }
    });
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/highpassfilter.zig");

test "HighpassFilterBlock" {
    // 129 taps, 0.2 cutoff, ComplexFloat32
    {
        var block = HighpassFilterBlock(std.math.Complex(f32), 129).init(0.2, .{});
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_taps_129_cutoff_0_2_complexfloat32});
    }

    // 129 taps, 0.7 cutoff, 3.0 nyquist, Bartlett window, ComplexFloat32
    {
        var block = HighpassFilterBlock(std.math.Complex(f32), 129).init(0.7, .{ .nyquist = 3.0, .window = WindowFunction.Bartlett });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_taps_129_cutoff_0_7_nyquist_3_0_window_bartlett_complexfloat32});
    }

    // 129 taps, 0.2 cutoff, Float32
    {
        var block = HighpassFilterBlock(f32, 129).init(0.2, .{});
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{f32}, .{&vectors.input_float32}, &[1]type{f32}, .{&vectors.output_taps_129_cutoff_0_2_float32});
    }

    // 129 taps, 0.7 cutoff, 3.0 nyquist, Bartlett window, Float32
    {
        var block = HighpassFilterBlock(f32, 129).init(0.7, .{ .nyquist = 3.0, .window = WindowFunction.Bartlett });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{f32}, .{&vectors.input_float32}, &[1]type{f32}, .{&vectors.output_taps_129_cutoff_0_7_nyquist_3_0_window_bartlett_float32});
    }
}
