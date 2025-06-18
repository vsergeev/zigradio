const std = @import("std");

const radio = @import("../../radio.zig");

////////////////////////////////////////////////////////////////////////////////
// WBFM Mono Demodulator Block
////////////////////////////////////////////////////////////////////////////////

pub const WBFMMonoDemodulatorBlock = struct {
    pub const Options = struct {
        deviation: f32 = 75e3,
        af_bandwidth: f32 = 15e3,
        af_deemphasis_tau: f32 = 75e-6,
    };

    block: radio.CompositeBlock,
    fm_demod: radio.blocks.FrequencyDiscriminatorBlock,
    af_filter: radio.blocks.LowpassFilterBlock(f32, 128),
    af_deemphasis: radio.blocks.SinglepoleLowpassFilterBlock(f32),

    pub fn init(options: Options) WBFMMonoDemodulatorBlock {
        return .{
            .block = radio.CompositeBlock.init(@This(), &.{"in1"}, &.{"out1"}),
            .fm_demod = radio.blocks.FrequencyDiscriminatorBlock.init(options.deviation),
            .af_filter = radio.blocks.LowpassFilterBlock(f32, 128).init(options.af_bandwidth, .{}),
            .af_deemphasis = radio.blocks.FMDeemphasisFilterBlock.init(options.af_deemphasis_tau),
        };
    }

    pub fn connect(self: *WBFMMonoDemodulatorBlock, flowgraph: *radio.Flowgraph) !void {
        try flowgraph.connect(&self.fm_demod.block, &self.af_filter.block);
        try flowgraph.connect(&self.af_filter.block, &self.af_deemphasis.block);

        try flowgraph.alias(&self.block, "in1", &self.fm_demod.block, "in1");
        try flowgraph.alias(&self.block, "out1", &self.af_deemphasis.block, "out1");
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "WBFMMonoDemodulatorBlock" {
    _ = WBFMMonoDemodulatorBlock.init(.{});
}
