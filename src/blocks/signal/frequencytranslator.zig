const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// Frequency Translator Block
////////////////////////////////////////////////////////////////////////////////

pub const FrequencyTranslatorBlock = struct {
    block: Block,
    offset: f32,
    omega: f32 = 0,
    phase: f32 = 0,

    pub fn init(offset: f32) FrequencyTranslatorBlock {
        return .{ .block = Block.init(@This()), .offset = offset };
    }

    pub fn initialize(self: *FrequencyTranslatorBlock, _: std.mem.Allocator) !void {
        self.omega = 2 * std.math.pi * (self.offset / try self.block.getRate(f32));
        self.phase = 0;
    }

    pub fn process(self: *FrequencyTranslatorBlock, x: []const std.math.Complex(f32), z: []std.math.Complex(f32)) !ProcessResult {
        for (x) |_, i| {
            z[i] = x[i].mul(.{ .re = std.math.cos(self.phase), .im = std.math.sin(self.phase) });
            self.phase += self.omega;
        }

        while (std.math.fabs(self.phase) > 2 * std.math.pi) {
            self.phase -= std.math.sign(self.omega) * 2 * std.math.pi;
        }

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("radio").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/frequencytranslator.zig");

test "FrequencyTranslatorBlock" {
    // Rotate by +0.2
    {
        var block = FrequencyTranslatorBlock.init(0.2);
        var tester = BlockTester.init(&block.block, 2e-5);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_pos_0_2});
    }

    // Rotate by -0.2
    {
        var block = FrequencyTranslatorBlock.init(-0.2);
        var tester = BlockTester.init(&block.block, 2e-5);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_neg_0_2});
    }
}
