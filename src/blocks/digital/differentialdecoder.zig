const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// Differential Decoder Block
////////////////////////////////////////////////////////////////////////////////

pub fn DifferentialDecoderBlock(comptime invert: bool) type {
    return struct {
        const Self = @This();

        block: Block,
        prev_bit: u1 = 0,

        pub fn init() Self {
            return .{ .block = Block.init(@This()) };
        }

        pub fn process(self: *Self, x: []const u1, z: []u1) !ProcessResult {
            for (x, 0..) |e, i| {
                z[i] = (self.prev_bit ^ e) ^ @intFromBool(invert);
                self.prev_bit = e;
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/digital/differentialdecoder.zig");

test "DifferentialDecoderBlock" {
    // Non-inverted
    {
        var block = DifferentialDecoderBlock(false).init();
        var tester = try BlockTester(&[1]type{u1}, &[1]type{u1}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input}, .{&vectors.output_non_inverted}, .{});
    }

    // Inverted
    {
        var block = DifferentialDecoderBlock(true).init();
        var tester = try BlockTester(&[1]type{u1}, &[1]type{u1}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input}, .{&vectors.output_inverted}, .{});
    }
}
