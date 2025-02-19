const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const FIRFilter = @import("./firfilter.zig").FIRFilter;

const WindowFunction = @import("../../radio.zig").utils.window.WindowFunction;
const firwinLowpass = @import("../../radio.zig").utils.filter.firwinLowpass;

////////////////////////////////////////////////////////////////////////////////
// Lowpass Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn LowpassFilterBlock(comptime T: type, comptime N: comptime_int) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            nyquist: ?f32 = null,
            window: WindowFunction = WindowFunction.Hamming,
        };

        block: Block,
        cutoff: f32,
        options: Options,
        filter: FIRFilter(T, f32, N),

        pub fn init(cutoff: f32, options: Options) Self {
            return .{ .block = Block.init(@This()), .cutoff = cutoff, .options = options, .filter = FIRFilter(T, f32, N).init() };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            // Compute Nyquist frequency
            const nyquist = self.options.nyquist orelse (self.block.getRate(f32) / 2);

            // Generate taps
            self.filter.taps = firwinLowpass(N, self.cutoff / nyquist, self.options.window);

            // Initialize filter
            return self.filter.initialize(allocator);
        }

        pub fn deinitialize(self: *Self, allocator: std.mem.Allocator) void {
            self.filter.deinitialize(allocator);
        }

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            return self.filter.process(x, y);
        }

        pub fn setCutoff(self: *Self, cutoff: f32) void {
            self.cutoff = cutoff;

            // Compute Nyquist frequency
            const nyquist = self.options.nyquist orelse (self.block.getRate(f32) / 2);

            // Generate taps
            self.filter.taps = firwinLowpass(N, self.cutoff / nyquist, self.options.window);

            // Update filter
            self.filter.updateTaps();
        }

        pub fn reset(self: *Self) void {
            self.filter.reset();
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;
const BlockFixture = @import("../../radio.zig").testing.BlockFixture;
const expectEqualVectors = @import("../../radio.zig").testing.expectEqualVectors;

const vectors = @import("../../vectors/blocks/signal/lowpassfilter.zig");

test "LowpassFilterBlock" {
    // 128 taps, 0.2 cutoff, ComplexFloat32
    {
        var block = LowpassFilterBlock(std.math.Complex(f32), 128).init(0.2, .{});
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_128_cutoff_0_2_complexfloat32}, .{});
    }

    // 128 taps, 0.7 cutoff, 3.0 nyquist, Bartlett window, ComplexFloat32
    {
        var block = LowpassFilterBlock(std.math.Complex(f32), 128).init(0.7, .{ .nyquist = 3.0, .window = WindowFunction.Bartlett });
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_128_cutoff_0_7_nyquist_3_0_window_bartlett_complexfloat32}, .{});
    }

    // 128 taps, 0.2 cutoff, Float32
    {
        var block = LowpassFilterBlock(f32, 128).init(0.2, .{});
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_taps_128_cutoff_0_2_float32}, .{});
    }

    // 128 taps, 0.7 cutoff, 3.0 nyquist, Bartlett window, Float32
    {
        var block = LowpassFilterBlock(f32, 128).init(0.7, .{ .nyquist = 3.0, .window = WindowFunction.Bartlett });
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_taps_128_cutoff_0_7_nyquist_3_0_window_bartlett_float32}, .{});
    }
}

test "LowpassFilterBlock change cutoff" {
    // 128 real taps, ComplexFloat32, 0.2 cutoff to 0.3 cutoff
    {
        var block = LowpassFilterBlock(std.math.Complex(f32), 128).init(0.2, .{});
        var fixture = try BlockFixture(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 2.0);
        defer fixture.deinit();

        const outputs1 = try fixture.process(.{&vectors.input_complexfloat32});
        try expectEqualVectors(std.math.Complex(f32), &vectors.output_taps_128_cutoff_0_2_complexfloat32, outputs1[0], 1e-6);

        block.setCutoff(0.3);
        block.reset();

        const outputs2 = try fixture.process(.{&vectors.input_complexfloat32});
        try expectEqualVectors(std.math.Complex(f32), &vectors.output_taps_128_cutoff_0_3_complexfloat32, outputs2[0], 1e-6);
    }
}
