const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

////////////////////////////////////////////////////////////////////////////////
// Real to Complex Block
////////////////////////////////////////////////////////////////////////////////

pub const RealToComplexBlock = struct {
    block: Block,

    pub fn init() RealToComplexBlock {
        return .{ .block = Block.init(@This()) };
    }

    pub fn process(_: *RealToComplexBlock, x: []const f32, z: []std.math.Complex(f32)) !ProcessResult {
        for (x, 0..) |e, i| z[i] = .{ .re = e, .im = 0 };
        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/realtocomplex.zig");

test "RealToComplexBlock" {
    {
        var block = RealToComplexBlock.init();
        var tester = try BlockTester(&[1]type{f32}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-5);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_complexfloat32}, .{});
    }
}
