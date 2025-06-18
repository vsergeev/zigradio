const std = @import("std");

const CompositeBlock = @import("../../radio.zig").CompositeBlock;
const Flowgraph = @import("../../radio.zig").Flowgraph;

const FrequencyDiscriminatorBlock = @import("../signal/frequencydiscriminator.zig").FrequencyDiscriminatorBlock;
const LowpassFilterBlock = @import("../signal/lowpassfilter.zig").LowpassFilterBlock;
const FMDeemphasisFilterBlock = @import("../signal/fmdeemphasisfilter.zig").FMDeemphasisFilterBlock;

////////////////////////////////////////////////////////////////////////////////
// WBFM Mono Demodulator Block
////////////////////////////////////////////////////////////////////////////////

pub const WBFMMonoDemodulatorBlock = struct {
    pub const Options = struct {
        deviation: f32 = 75e3,
        af_bandwidth: f32 = 15e3,
        af_deemphasis_tau: f32 = 75e-6,
    };

    block: CompositeBlock,
    fm_demod: FrequencyDiscriminatorBlock,
    af_filter: LowpassFilterBlock(f32, 128),
    af_deemphasis: FMDeemphasisFilterBlock,

    pub fn init(options: Options) WBFMMonoDemodulatorBlock {
        return .{
            .block = CompositeBlock.init(@This(), &.{"in1"}, &.{"out1"}),
            .fm_demod = FrequencyDiscriminatorBlock.init(options.deviation),
            .af_filter = LowpassFilterBlock(f32, 128).init(options.af_bandwidth, .{}),
            .af_deemphasis = FMDeemphasisFilterBlock.init(options.af_deemphasis_tau),
        };
    }

    pub fn connect(self: *WBFMMonoDemodulatorBlock, flowgraph: *Flowgraph) !void {
        try flowgraph.connect(&self.fm_demod.block, &self.af_filter.block);
        try flowgraph.connect(&self.af_filter.block, &self.af_deemphasis.block);

        try flowgraph.alias(&self.block, "in1", &self.fm_demod.block, "in1");
        try flowgraph.alias(&self.block, "out1", &self.af_deemphasis.block, "out1");
    }
};
