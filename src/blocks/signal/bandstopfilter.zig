const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const FIRFilter = @import("./firfilter.zig").FIRFilter;

const WindowFunction = @import("../../radio.zig").utils.window.WindowFunction;
const firwinBandstop = @import("../../radio.zig").utils.filter.firwinBandstop;

////////////////////////////////////////////////////////////////////////////////
// Bandstop Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn BandstopFilterBlock(comptime T: type, comptime N: comptime_int) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            nyquist: ?f32 = null,
            window: WindowFunction = WindowFunction.Hamming,
        };

        block: Block,
        cutoffs: struct { f32, f32 },
        options: Options,
        filter: FIRFilter(T, f32, N),

        pub fn init(cutoffs: struct { f32, f32 }, options: Options) Self {
            return .{ .block = Block.init(@This()), .cutoffs = cutoffs, .options = options, .filter = FIRFilter(T, f32, N).init() };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            // Compute Nyquist frequency
            const nyquist = self.options.nyquist orelse (self.block.getRate(f32) / 2);

            // Generate taps
            self.filter.taps = firwinBandstop(N, .{ self.cutoffs[0] / nyquist, self.cutoffs[1] / nyquist }, self.options.window);

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

const vectors = @import("../../vectors/blocks/signal/bandstopfilter.zig");

test "BandstopFilterBlock" {
    // 129 taps, [0.1, 0.3] cutoffs, ComplexFloat32
    {
        var block = BandstopFilterBlock(std.math.Complex(f32), 129).init(.{ 0.1, 0.3 }, .{});
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_129_cutoff_0_1_0_3_complexfloat32});
    }

    // 129 taps, [0.4, 0.6] cutoffs, 3.0 nyquist, Bartlett window, ComplexFloat32
    {
        var block = BandstopFilterBlock(std.math.Complex(f32), 129).init(.{ 0.4, 0.6 }, .{ .nyquist = 3.0, .window = WindowFunction.Bartlett });
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_129_cutoff_0_4_0_6_nyquist_3_0_window_bartlett_complexfloat32});
    }

    // 129 taps, [0.1, 0.3] cutoffs, Float32
    {
        var block = BandstopFilterBlock(f32, 129).init(.{ 0.1, 0.3 }, .{});
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_taps_129_cutoff_0_1_0_3_float32});
    }

    // 129 taps, [0.4, 0.6] cutoffs, 3.0 nyquist, Bartlett window, Float32
    {
        var block = BandstopFilterBlock(f32, 129).init(.{ 0.4, 0.6 }, .{ .nyquist = 3.0, .window = WindowFunction.Bartlett });
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_taps_129_cutoff_0_4_0_6_nyquist_3_0_window_bartlett_float32});
    }
}
