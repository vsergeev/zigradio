// @block AMEnvelopeDemodulatorBlock
// @description Demodulate a baseband, double-sideband amplitude modulated
//
// $$ y[n] = \text{AMDemodulate}(x[n], \text{bandwidth}) $$
//
// complex-valued signal with an envelope detector.
// @category Demodulation
// @param options Options Additional options:
//      * `bandwidth` (`f32`, bandwidth in Hz, default 5e3)
// @signature in1:Complex(f32) > out1:f32
// @usage
// var demod = radio.blocks.AMEnvelopeDemodulatorBlock.init(.{});
// try top.connect(&src.block, &demod.block);
// try top.connect(&demod.block, &snk.block);

const std = @import("std");

const radio = @import("../../radio.zig");

////////////////////////////////////////////////////////////////////////////////
// AM Envelope Demodulator Block
////////////////////////////////////////////////////////////////////////////////

pub const AMEnvelopeDemodulatorBlock = struct {
    pub const Options = struct {
        bandwidth: f32 = 5e3,
    };

    block: radio.CompositeBlock,
    am_demod: radio.blocks.ComplexMagnitudeBlock,
    dcr_filter: radio.blocks.SinglepoleHighpassFilterBlock(f32),
    af_filter: radio.blocks.LowpassFilterBlock(f32, 64),

    pub fn init(options: Options) AMEnvelopeDemodulatorBlock {
        return .{
            .block = radio.CompositeBlock.init(@This(), &.{"in1"}, &.{"out1"}),
            .am_demod = radio.blocks.ComplexMagnitudeBlock.init(),
            .dcr_filter = radio.blocks.SinglepoleHighpassFilterBlock(f32).init(100),
            .af_filter = radio.blocks.LowpassFilterBlock(f32, 64).init(options.bandwidth, .{}),
        };
    }

    pub fn connect(self: *AMEnvelopeDemodulatorBlock, flowgraph: *radio.Flowgraph) !void {
        try flowgraph.connect(&self.am_demod.block, &self.dcr_filter.block);
        try flowgraph.connect(&self.dcr_filter.block, &self.af_filter.block);

        try flowgraph.alias(&self.block, "in1", &self.am_demod.block, "in1");
        try flowgraph.alias(&self.block, "out1", &self.af_filter.block, "out1");
    }

    pub fn setBandwidth(self: *AMEnvelopeDemodulatorBlock, flowgraph: *radio.Flowgraph, bandwidth: f32) !void {
        try flowgraph.call(&self.af_filter.block, radio.blocks.LowpassFilterBlock(f32, 64).setCutoff, .{bandwidth});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "AMEnvelopeDemodulatorBlock" {
    _ = AMEnvelopeDemodulatorBlock.init(.{});
}
