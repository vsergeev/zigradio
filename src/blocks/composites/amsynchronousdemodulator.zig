// @block AMSynchronousDemodulatorBlock
// @description Demodulate a baseband, double-sideband amplitude modulated
// complex-valued signal with a synchronous detector.
//
// $$ y[n] = \text{AMDemodulate}(x[n], \text{bandwidth}) $$
//
// @category Demodulation
// @param options Options Additional options:
//      * `bandwidth` (`f32`, bandwidth in Hz, default 5e3)
// @signature in1:Complex(f32) > out1:f32
// @usage
// var demod = radio.blocks.AMSynchronousDemodulatorBlock.init(.{});
// try top.connect(&src.block, &demod.block);
// try top.connect(&demod.block, &snk.block);

const std = @import("std");

const radio = @import("../../radio.zig");

////////////////////////////////////////////////////////////////////////////////
// AM Synchronous Demodulator Block
////////////////////////////////////////////////////////////////////////////////

pub const AMSynchronousDemodulatorBlock = struct {
    pub const Options = struct {
        bandwidth: f32 = 5e3,
    };

    block: radio.CompositeBlock,
    pll: radio.blocks.ComplexPLLBlock,
    mixer: radio.blocks.MultiplyConjugateBlock,
    am_demod: radio.blocks.ComplexToRealBlock,
    dcr_filter: radio.blocks.SinglepoleHighpassFilterBlock(f32),
    af_filter: radio.blocks.LowpassFilterBlock(f32, 64),

    pub fn init(options: Options) AMSynchronousDemodulatorBlock {
        return .{
            .block = radio.CompositeBlock.init(@This(), &.{"in1"}, &.{"out1"}),
            .pll = radio.blocks.ComplexPLLBlock.init(500, .{ -100, 100 }, .{}),
            .mixer = radio.blocks.MultiplyConjugateBlock.init(),
            .am_demod = radio.blocks.ComplexToRealBlock.init(),
            .dcr_filter = radio.blocks.SinglepoleHighpassFilterBlock(f32).init(100),
            .af_filter = radio.blocks.LowpassFilterBlock(f32, 64).init(options.bandwidth, .{}),
        };
    }

    pub fn connect(self: *AMSynchronousDemodulatorBlock, flowgraph: *radio.Flowgraph) !void {
        try flowgraph.connectPort(&self.pll.block, "out1", &self.mixer.block, "in2");
        try flowgraph.connect(&self.mixer.block, &self.am_demod.block);
        try flowgraph.connect(&self.am_demod.block, &self.dcr_filter.block);
        try flowgraph.connect(&self.dcr_filter.block, &self.af_filter.block);

        try flowgraph.alias(&self.block, "in1", &self.mixer.block, "in1");
        try flowgraph.alias(&self.block, "in1", &self.pll.block, "in1");
        try flowgraph.alias(&self.block, "out1", &self.af_filter.block, "out1");
    }

    pub fn setBandwidth(self: *AMSynchronousDemodulatorBlock, flowgraph: *radio.Flowgraph, bandwidth: f32) !void {
        try flowgraph.call(&self.af_filter.block, radio.blocks.LowpassFilterBlock(f32, 64).setCutoff, .{bandwidth});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "AMSynchronousDemodulatorBlock" {
    _ = AMSynchronousDemodulatorBlock.init(.{});
}
