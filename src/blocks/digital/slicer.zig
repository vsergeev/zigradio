// @block SlicerBlock
// @description Slice a signal into symbols using the specified slicer.
// @category Digital
// @cparam slicer type Slicer type implementing `fn process(value: T) U`
// @signature in1:T > out1:U
// @usage
// var slicer = radio.blocks.SlicerBlock(radio.blocks.BinarySlicer).init();

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// Slicer Block
////////////////////////////////////////////////////////////////////////////////

pub const BinarySlicer = struct {
    pub inline fn process(value: f32) u1 {
        return @intFromBool(value > 0.0);
    }
};

pub fn SlicerBlock(comptime slicer: type) type {
    return struct {
        const Self = @This();

        block: Block,

        pub fn init() Self {
            return .{ .block = Block.init(@This()) };
        }

        fn SlicerInputType() type {
            return @typeInfo(@TypeOf(slicer.process)).@"fn".params[0].type.?;
        }

        fn SlicerOutputType() type {
            return @typeInfo(@TypeOf(slicer.process)).@"fn".return_type.?;
        }

        pub fn process(_: *Self, x: []const SlicerInputType(), z: []SlicerOutputType()) !ProcessResult {
            for (x, 0..) |e, i| {
                z[i] = slicer.process(e);
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/digital/slicer.zig");

test "SlicerBlock" {
    // Binary Slicer
    {
        var block = SlicerBlock(BinarySlicer).init();
        var tester = try BlockTester(&[1]type{f32}, &[1]type{u1}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_bit}, .{});
    }
}
