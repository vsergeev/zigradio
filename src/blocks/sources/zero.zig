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
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.checkSource(&[1]type{
            std.math.Complex(f32),
        }, .{&[_]std.math.Complex(f32){.{ .re = 0, .im = 0 }} ** 64});
    }

    // Float32
    {
        var block = ZeroSource(f32).init(2);
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.checkSource(&[1]type{
            f32,
        }, .{&[_]f32{0} ** 64});
    }
}
