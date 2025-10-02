// @block AddBlock
// @description Add two signals.
//
// $$ y[n] = x_{1}[n] + x_{2}[n] $$
//
// @category Math Operations
// @ctparam T type Complex(f32), f32, etc.
// @signature in1:T in2:T > out1:T
// @usage
// var summer = radio.blocks.AddBlock(std.math.Complex(f32)).init();
// try top.connectPort(&src1.block, "out1", &summer.block, "in1");
// try top.connectPort(&src2.block, "out1", &summer.block, "in2");
// try top.connect(&summer.block, &sink.block);

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

const add = @import("../../radio.zig").utils.math.add;

////////////////////////////////////////////////////////////////////////////////
// Add Block
////////////////////////////////////////////////////////////////////////////////

pub fn AddBlock(comptime T: type) type {
    return struct {
        const Self = @This();

        block: Block,

        pub fn init() Self {
            return .{ .block = Block.init(@This()) };
        }

        pub fn process(_: *Self, x: []const T, y: []const T, z: []T) !ProcessResult {
            for (x, 0..) |_, i| {
                z[i] = add(T, x[i], y[i]);
            }

            return ProcessResult.init(&[2]usize{ x.len, x.len }, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/add.zig");

test "AddBlock" {
    // ComplexFloat32
    {
        var block = AddBlock(std.math.Complex(f32)).init();
        var tester = try BlockTester(&[2]type{ std.math.Complex(f32), std.math.Complex(f32) }, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{ &vectors.input1_complexfloat32, &vectors.input2_complexfloat32 }, .{&vectors.output_complexfloat32}, .{});
    }

    // Float32
    {
        var block = AddBlock(f32).init();
        var tester = try BlockTester(&[2]type{ f32, f32 }, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{ &vectors.input1_float32, &vectors.input2_float32 }, .{&vectors.output_float32}, .{});
    }
}
