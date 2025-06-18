const std = @import("std");

const CompositeBlock = @import("../../radio.zig").CompositeBlock;
const Flowgraph = @import("../../radio.zig").Flowgraph;

const LowpassFilterBlock = @import("../signal/lowpassfilter.zig").LowpassFilterBlock;
const FrequencyDiscriminatorBlock = @import("../signal/frequencydiscriminator.zig").FrequencyDiscriminatorBlock;

////////////////////////////////////////////////////////////////////////////////
// NBFM Demodulator Block
////////////////////////////////////////////////////////////////////////////////

pub const NBFMDemodulatorBlock = struct {
    pub const Options = struct {
        bandwidth: f32 = 5e3,
        deviation: f32 = 4e3,
    };

    block: CompositeBlock,
    bb_filter: LowpassFilterBlock(std.math.Complex(f32), 64),
    fm_demod: FrequencyDiscriminatorBlock,
    af_filter: LowpassFilterBlock(f32, 64),

    pub fn init(options: Options) NBFMDemodulatorBlock {
        return .{
            .block = CompositeBlock.init(@This(), &.{"in1"}, &.{"out1"}),
            .bb_filter = LowpassFilterBlock(std.math.Complex(f32), 64).init(options.deviation + options.bandwidth, .{}),
            .fm_demod = FrequencyDiscriminatorBlock.init(options.deviation),
            .af_filter = LowpassFilterBlock(f32, 64).init(options.bandwidth, .{}),
        };
    }

    pub fn connect(self: *NBFMDemodulatorBlock, flowgraph: *Flowgraph) !void {
        try flowgraph.connect(&self.bb_filter.block, &self.fm_demod.block);
        try flowgraph.connect(&self.fm_demod.block, &self.af_filter.block);

        try flowgraph.alias(&self.block, "in1", &self.bb_filter.block, "in1");
        try flowgraph.alias(&self.block, "out1", &self.af_filter.block, "out1");
    }

    pub fn setBandwidth(self: *NBFMDemodulatorBlock, flowgraph: *Flowgraph, bandwidth: f32) !void {
        try flowgraph.call(&self.af_filter.block, LowpassFilterBlock(f32, 64).setCutoff, .{bandwidth});
    }
};
