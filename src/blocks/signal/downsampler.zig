// @block DownsamplerBlock
// @description Downsample a complex or real valued signal. This block reduces
// the sample rate for downstream blocks in the flow graph by a factor of M.
//
// $$ y[n] = x[nM] $$
//
// Note: this block performs no anti-alias filtering.
//
// @category Sample Rate Manipulation
// @ctparam T type Complex(f32), f32, etc.
// @param factor usize Downsampling factor
// @signature in:T > out:T
// @usage
// var downsampler = radio.blocks.DownsamplerBlock(std.math.Complex(f32)).init(4);

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// Downsampler Block
////////////////////////////////////////////////////////////////////////////////

pub fn DownsamplerBlock(comptime T: type) type {
    return struct {
        const Self = @This();

        block: Block,
        factor: usize,
        index: usize = 0,

        pub fn init(factor: usize) Self {
            return .{ .block = Block.init(@This()), .factor = factor };
        }

        pub fn setRate(self: *Self, upstream_rate: f64) !f64 {
            return upstream_rate / @as(f64, @floatFromInt(self.factor));
        }

        pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
            self.index = 0;
        }

        pub fn process(self: *Self, x: []const T, z: []T) !ProcessResult {
            var i: usize = 0;
            while (self.index < x.len) : ({
                self.index += self.factor;
                i += 1;
            }) {
                z[i] = x[self.index];
            }
            self.index -= x.len;

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{i});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/downsampler.zig");

test "DownsamplerBlock" {
    // Factor 1, Complex Float 32
    {
        var block = DownsamplerBlock(std.math.Complex(f32)).init(1);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_factor_1_complexfloat32}, .{});
    }

    // Factor 2, Complex Float 32
    {
        var block = DownsamplerBlock(std.math.Complex(f32)).init(2);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_factor_2_complexfloat32}, .{});
    }

    // Factor 3, Complex Float 32
    {
        var block = DownsamplerBlock(std.math.Complex(f32)).init(3);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_factor_3_complexfloat32}, .{});
    }

    // Factor 4, Complex Float 32
    {
        var block = DownsamplerBlock(std.math.Complex(f32)).init(4);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_factor_4_complexfloat32}, .{});
    }

    // Factor 7, Complex Float 32
    {
        var block = DownsamplerBlock(std.math.Complex(f32)).init(7);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_factor_7_complexfloat32}, .{});
    }

    // Factor 16, Complex Float 32
    {
        var block = DownsamplerBlock(std.math.Complex(f32)).init(16);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_factor_16_complexfloat32}, .{});
    }

    // Factor 1, Float 32
    {
        var block = DownsamplerBlock(f32).init(1);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_factor_1_float32}, .{});
    }

    // Factor 2, Float 32
    {
        var block = DownsamplerBlock(f32).init(2);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_factor_2_float32}, .{});
    }

    // Factor 3, Float 32
    {
        var block = DownsamplerBlock(f32).init(3);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_factor_3_float32}, .{});
    }

    // Factor 4, Float 32
    {
        var block = DownsamplerBlock(f32).init(4);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_factor_4_float32}, .{});
    }

    // Factor 7, Float 32
    {
        var block = DownsamplerBlock(f32).init(7);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_factor_7_float32}, .{});
    }

    // Factor 16, Float 32
    {
        var block = DownsamplerBlock(f32).init(16);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_factor_16_float32}, .{});
    }
}
