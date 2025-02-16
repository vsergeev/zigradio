const std = @import("std");

const CompositeBlock = @import("../../radio.zig").CompositeBlock;
const Flowgraph = @import("../../radio.zig").Flowgraph;

const ComplexMagnitudeBlock = @import("../signal/complexmagnitude.zig").ComplexMagnitudeBlock;
const SinglepoleHighpassFilterBlock = @import("../signal/singlepolehighpassfilter.zig").SinglepoleHighpassFilterBlock;
const LowpassFilterBlock = @import("../signal/lowpassfilter.zig").LowpassFilterBlock;

////////////////////////////////////////////////////////////////////////////////
// AM Envelope Demodulator Block
////////////////////////////////////////////////////////////////////////////////

pub const AMEnvelopeDemodulatorBlock = struct {
    pub const Options = struct {
        bandwidth: f32 = 5e3,
    };

    block: CompositeBlock,
    am_demod: ComplexMagnitudeBlock,
    dcr_filter: SinglepoleHighpassFilterBlock(f32),
    af_filter: LowpassFilterBlock(f32, 64),

    pub fn init(options: Options) AMEnvelopeDemodulatorBlock {
        return .{
            .block = CompositeBlock.init(@This(), &.{"in1"}, &.{"out1"}),
            .am_demod = ComplexMagnitudeBlock.init(),
            .dcr_filter = SinglepoleHighpassFilterBlock(f32).init(100),
            .af_filter = LowpassFilterBlock(f32, 64).init(options.bandwidth, .{}),
        };
    }

    pub fn connect(self: *AMEnvelopeDemodulatorBlock, flowgraph: *Flowgraph) !void {
        try flowgraph.connect(&self.am_demod.block, &self.dcr_filter.block);
        try flowgraph.connect(&self.dcr_filter.block, &self.af_filter.block);

        try flowgraph.alias(&self.block, "in1", &self.am_demod.block, "in1");
        try flowgraph.alias(&self.block, "out1", &self.af_filter.block, "out1");
    }

    pub fn setBandwidth(self: *AMEnvelopeDemodulatorBlock, flowgraph: *Flowgraph, bandwidth: f32) !void {
        try flowgraph.call(&self.af_filter.block, LowpassFilterBlock(f32, 64).setCutoff, .{bandwidth});
    }
};
