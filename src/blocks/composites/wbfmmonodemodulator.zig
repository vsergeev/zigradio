// @block WBFMMonoDemodulatorBlock
// @description Demodulate a baseband, broadcast radio wideband FM modulated complex-valued
// signal into the real-valued mono channel (L+R) signal.
//
// $$ y[n] = \text{WBFMMonoDemodulate}(x[n], \text{deviation}, \text{bandwidth}, \tau) $$
//
// @category Demodulation
// @param options Options Additional options:
//      * `deviation` (`f32`, deviation in Hz, default 75e3)
//      * `af_bandwidth` (`f32`, audio bandwidth in Hz, default 15e3)
//      * `af_deemphasis_tau` (`f32`, audio de-emphasis time constant, default 75e-6)
// @signature in1:Complex(f32) > out1:f32
// @usage
// var demod = radio.blocks.WBFMMonoDemodulatorBlock.init(.{});
// try top.connect(&src.block, &demod.block);
// try top.connect(&demod.block, &snk.block);

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
