// @block ZeroSource
// @description Source a zero-valued signal of the specified type.
// @category Sources
// @ctparam T type Complex(f32), f32, u1, etc.
// @param rate f64 Sample rate in Hz
// @signature > out:T
// @usage
// var src = radio.blocks.ZeroSource(std.math.Complex(f32)).init(1e6);
// try top.connect(&src.block, &snk.block);

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// Zero Source
////////////////////////////////////////////////////////////////////////////////

pub fn ZeroSource(comptime T: type) type {
    return struct {
        const Self = @This();

        block: Block,
        rate: f64,

        pub fn init(rate: f64) Self {
            return .{ .block = Block.init(@This()), .rate = rate };
        }

        pub fn setRate(self: *Self, _: f64) !f64 {
            return self.rate;
        }

        pub fn process(_: *Self, z: []T) !ProcessResult {
            return ProcessResult.init(&[0]usize{}, &[1]usize{z.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

test "ZeroSource" {
    // ComplexFloat32
    {
        var block = ZeroSource(std.math.Complex(f32)).init(2);
        var tester = try BlockTester(&[0]type{}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.checkSource(.{&[_]std.math.Complex(f32){.{ .re = 0, .im = 0 }} ** 64}, .{});
    }

    // Float32
    {
        var block = ZeroSource(f32).init(2);
        var tester = try BlockTester(&[0]type{}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.checkSource(.{&[_]f32{0} ** 64}, .{});
    }
}
