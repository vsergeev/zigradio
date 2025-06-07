const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const FIRFilter = @import("./firfilter.zig").FIRFilter;

const WindowFunction = @import("../../radio.zig").utils.window.WindowFunction;
const firwinComplexBandstop = @import("../../radio.zig").utils.filter.firwinComplexBandstop;

////////////////////////////////////////////////////////////////////////////////
// Complex Bandstop Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn ComplexBandstopFilterBlock(comptime N: comptime_int) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            nyquist: ?f32 = null,
            window: WindowFunction = WindowFunction.Hamming,
        };

        block: Block,
        cutoffs: struct { f32, f32 },
        options: Options,
        filter: FIRFilter(std.math.Complex(f32), std.math.Complex(f32)),

        pub fn init(cutoffs: struct { f32, f32 }, options: Options) Self {
            return .{ .block = Block.init(@This()), .cutoffs = cutoffs, .options = options, .filter = FIRFilter(std.math.Complex(f32), std.math.Complex(f32)).init() };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            // Compute Nyquist frequency
            const nyquist = self.options.nyquist orelse (self.block.getRate(f32) / 2);

            // Generate taps
            const taps = firwinComplexBandstop(N, .{ self.cutoffs[0] / nyquist, self.cutoffs[1] / nyquist }, self.options.window);

            // Initialize filter
            return self.filter.initialize(allocator, taps[0..]);
        }

        pub fn deinitialize(self: *Self, allocator: std.mem.Allocator) void {
            self.filter.deinitialize(allocator);
        }

        pub fn process(self: *Self, x: []const std.math.Complex(f32), y: []std.math.Complex(f32)) !ProcessResult {
            return self.filter.process(x, y);
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/complexbandstopfilter.zig");

test "ComplexBandstopFilterBlock" {
    // 129 taps, [0.1, 0.3] cutoffs
    {
        var block = ComplexBandstopFilterBlock(129).init(.{ 0.1, 0.3 }, .{});
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_129_cutoff_0_1_0_3}, .{});
    }

    // 129 taps, [-0.1, -0.3] cutoffs
    {
        var block = ComplexBandstopFilterBlock(129).init(.{ -0.1, -0.3 }, .{});
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_129_cutoff_m0_1_m0_3}, .{});
    }

    // 129 taps, [-0.2, 0.2] cutoffs
    {
        var block = ComplexBandstopFilterBlock(129).init(.{ -0.2, 0.2 }, .{});
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_129_cutoff_m0_2_p0_2}, .{});
    }

    // 129 taps, [0.4, 0.6] cutoffs, 3.0 nyquist, Bartlett window
    {
        var block = ComplexBandstopFilterBlock(129).init(.{ 0.4, 0.6 }, .{ .nyquist = 3.0, .window = WindowFunction.Bartlett });
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_129_cutoff_0_4_0_6_nyquist_3_0_window_bartlett}, .{});
    }
}
