const std = @import("std");

const radio = @import("../../radio.zig");

////////////////////////////////////////////////////////////////////////////////
// NBFM Demodulator Block
////////////////////////////////////////////////////////////////////////////////

pub const NBFMDemodulatorBlock = struct {
    pub const Options = struct {
        bandwidth: f32 = 5e3,
        deviation: f32 = 4e3,
    };

    block: radio.CompositeBlock,
    bb_filter: radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 64),
    fm_demod: radio.blocks.FrequencyDiscriminatorBlock,
    af_filter: radio.blocks.LowpassFilterBlock(f32, 64),

    pub fn init(options: Options) NBFMDemodulatorBlock {
        return .{
            .block = radio.CompositeBlock.init(@This(), &.{"in1"}, &.{"out1"}),
            .bb_filter = radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 64).init(options.deviation + options.bandwidth, .{}),
            .fm_demod = radio.blocks.FrequencyDiscriminatorBlock.init(options.deviation),
            .af_filter = radio.blocks.LowpassFilterBlock(f32, 64).init(options.bandwidth, .{}),
        };
    }

    pub fn connect(self: *NBFMDemodulatorBlock, flowgraph: *radio.Flowgraph) !void {
        try flowgraph.connect(&self.bb_filter.block, &self.fm_demod.block);
        try flowgraph.connect(&self.fm_demod.block, &self.af_filter.block);

        try flowgraph.alias(&self.block, "in1", &self.bb_filter.block, "in1");
        try flowgraph.alias(&self.block, "out1", &self.af_filter.block, "out1");
    }

    pub fn setBandwidth(self: *NBFMDemodulatorBlock, flowgraph: *radio.Flowgraph, bandwidth: f32) !void {
        try flowgraph.call(&self.af_filter.block, radio.blocks.LowpassFilterBlock(f32, 64).setCutoff, .{bandwidth});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "NBFMDemodulatorBlock" {
    _ = NBFMDemodulatorBlock.init(.{});
}
