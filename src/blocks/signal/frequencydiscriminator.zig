const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// Frequency Discriminator Block
////////////////////////////////////////////////////////////////////////////////

pub const FrequencyDiscriminatorBlock = struct {
    block: Block,
    gain: f32,
    prev_sample: std.math.Complex(f32) = .{ .re = 0, .im = 0 },

    pub fn init(modulation_index: f32) FrequencyDiscriminatorBlock {
        return .{ .block = Block.init(@This()), .gain = 2 * std.math.pi * modulation_index };
    }

    pub fn initialize(self: *FrequencyDiscriminatorBlock, _: std.mem.Allocator) !void {
        self.prev_sample = .{ .re = 0, .im = 0 };
    }

    pub fn process(self: *FrequencyDiscriminatorBlock, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        for (x, 0..) |_, i| {
            const tmp = x[i].mul((if (i == 0) self.prev_sample else x[i - 1]).conjugate());
            z[i] = std.math.atan2(f32, tmp.im, tmp.re) * (1.0 / self.gain);
        }

        self.prev_sample = x[x.len - 1];

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/frequencydiscriminator.zig");

test "FrequencyDiscriminatorBlock" {
    // Modulation index 1.0
    {
        var block = FrequencyDiscriminatorBlock.init(1.0);
        var tester = BlockTester.init(&block.block, 1e-5);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{f32}, .{&vectors.output_modulation_index_1});
    }

    // Modulation index 5.0
    {
        var block = FrequencyDiscriminatorBlock.init(5.0);
        var tester = BlockTester.init(&block.block, 1e-5);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{f32}, .{&vectors.output_modulation_index_5});
    }
}
