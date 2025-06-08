const std = @import("std");

const CompositeBlock = @import("../../radio.zig").CompositeBlock;
const Flowgraph = @import("../../radio.zig").Flowgraph;

const ComplexBandpassFilterBlock = @import("../signal/complexbandpassfilter.zig").ComplexBandpassFilterBlock;
const ComplexPLLBlock = @import("../signal/complexpll.zig").ComplexPLLBlock;
const MultiplyConjugateBlock = @import("../signal/multiplyconjugate.zig").MultiplyConjugateBlock;
const ComplexToRealBlock = @import("../signal/complextoreal.zig").ComplexToRealBlock;
const SinglepoleHighpassFilterBlock = @import("../signal/singlepolehighpassfilter.zig").SinglepoleHighpassFilterBlock;
const LowpassFilterBlock = @import("../signal/lowpassfilter.zig").LowpassFilterBlock;

////////////////////////////////////////////////////////////////////////////////
// AM Synchronous Demodulator Block
////////////////////////////////////////////////////////////////////////////////

pub const AMSynchronousDemodulatorBlock = struct {
    pub const Options = struct {
        bandwidth: f32 = 5e3,
    };

    block: CompositeBlock,
    pll: ComplexPLLBlock,
    mixer: MultiplyConjugateBlock,
    am_demod: ComplexToRealBlock,
    dcr_filter: SinglepoleHighpassFilterBlock(f32),
    af_filter: LowpassFilterBlock(f32, 64),

    pub fn init(options: Options) AMSynchronousDemodulatorBlock {
        return .{
            .block = CompositeBlock.init(@This(), &.{"in1"}, &.{"out1"}),
            .pll = ComplexPLLBlock.init(500, -100, 100, .{}),
            .mixer = MultiplyConjugateBlock.init(),
            .am_demod = ComplexToRealBlock.init(),
            .dcr_filter = SinglepoleHighpassFilterBlock(f32).init(100),
            .af_filter = LowpassFilterBlock(f32, 128).init(options.bandwidth, .{}),
        };
    }

    pub fn connect(self: *AMSynchronousDemodulatorBlock, flowgraph: *Flowgraph) !void {
        try flowgraph.connectPort(&self.pll.block, "out1", &self.mixer.block, "in2");
        try flowgraph.connect(&self.mixer.block, &self.am_demod.block);
        try flowgraph.connect(&self.am_demod.block, &self.dcr_filter.block);
        try flowgraph.connect(&self.dcr_filter.block, &self.af_filter.block);

        try flowgraph.alias(&self.block, "in1", &self.mixer.block, "in1");
        try flowgraph.alias(&self.block, "in1", &self.pll.block, "in1");
        try flowgraph.alias(&self.block, "out1", &self.af_filter.block, "out1");
    }

    pub fn setBandwidth(self: *AMSynchronousDemodulatorBlock, flowgraph: *Flowgraph, bandwidth: f32) !void {
        try flowgraph.call(&self.af_filter.block, LowpassFilterBlock(f32, 64).setCutoff, .{bandwidth});
    }
};
