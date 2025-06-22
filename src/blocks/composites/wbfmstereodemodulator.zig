const std = @import("std");

const radio = @import("../../radio.zig");

////////////////////////////////////////////////////////////////////////////////
// WBFM Stereo Demodulator Block
////////////////////////////////////////////////////////////////////////////////

pub const WBFMStereoDemodulatorBlock = struct {
    pub const Options = struct {
        deviation: f32 = 75e3,
        af_bandwidth: f32 = 15e3,
        af_deemphasis_tau: f32 = 75e-6,
    };

    block: radio.CompositeBlock,
    fm_demod: radio.blocks.FrequencyDiscriminatorBlock,
    real_to_complex: radio.blocks.RealToComplexBlock,
    delay: radio.blocks.DelayBlock(std.math.Complex(f32)),
    pilot_filter: radio.blocks.ComplexBandpassFilterBlock(129),
    pilot_pll: radio.blocks.ComplexPLLBlock,
    mixer: radio.blocks.MultiplyConjugateBlock,
    lpr_filter: radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 128),
    lpr_am_demod: radio.blocks.ComplexToRealBlock,
    lmr_filter: radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 128),
    lmr_am_demod: radio.blocks.ComplexToRealBlock,
    l_summer: radio.blocks.AddBlock(f32),
    l_af_deemphasis: radio.blocks.SinglepoleLowpassFilterBlock(f32),
    r_summer: radio.blocks.SubtractBlock(f32),
    r_af_deemphasis: radio.blocks.SinglepoleLowpassFilterBlock(f32),

    pub fn init(options: Options) WBFMStereoDemodulatorBlock {
        return .{
            .block = radio.CompositeBlock.init(@This(), &.{"in1"}, &.{ "out1", "out2" }),
            .fm_demod = radio.blocks.FrequencyDiscriminatorBlock.init(options.deviation),
            .real_to_complex = radio.blocks.RealToComplexBlock.init(),
            .delay = radio.blocks.DelayBlock(std.math.Complex(f32)).init(129),
            .pilot_filter = radio.blocks.ComplexBandpassFilterBlock(129).init(.{ 18e3, 20e3 }, .{}),
            .pilot_pll = radio.blocks.ComplexPLLBlock.init(500, .{ 19e3 - 100, 19e3 + 100 }, .{ .multiplier = 2 }),
            .mixer = radio.blocks.MultiplyConjugateBlock.init(),
            // L+R
            .lpr_filter = radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 128).init(options.af_bandwidth, .{}),
            .lpr_am_demod = radio.blocks.ComplexToRealBlock.init(),
            // L-R
            .lmr_filter = radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 128).init(options.af_bandwidth, .{}),
            .lmr_am_demod = radio.blocks.ComplexToRealBlock.init(),
            // L
            .l_summer = radio.blocks.AddBlock(f32).init(),
            .l_af_deemphasis = radio.blocks.FMDeemphasisFilterBlock.init(options.af_deemphasis_tau),
            // R
            .r_summer = radio.blocks.SubtractBlock(f32).init(),
            .r_af_deemphasis = radio.blocks.FMDeemphasisFilterBlock.init(options.af_deemphasis_tau),
        };
    }

    pub fn connect(self: *WBFMStereoDemodulatorBlock, flowgraph: *radio.Flowgraph) !void {
        try flowgraph.connect(&self.fm_demod.block, &self.real_to_complex.block);
        try flowgraph.connect(&self.real_to_complex.block, &self.pilot_filter.block);
        try flowgraph.connect(&self.real_to_complex.block, &self.delay.block);
        try flowgraph.connect(&self.pilot_filter.block, &self.pilot_pll.block);
        try flowgraph.connectPort(&self.delay.block, "out1", &self.mixer.block, "in1");
        try flowgraph.connectPort(&self.pilot_pll.block, "out1", &self.mixer.block, "in2");
        try flowgraph.connect(&self.delay.block, &self.lpr_filter.block);
        try flowgraph.connect(&self.mixer.block, &self.lmr_filter.block);
        try flowgraph.connect(&self.lpr_filter.block, &self.lpr_am_demod.block);
        try flowgraph.connect(&self.lmr_filter.block, &self.lmr_am_demod.block);
        try flowgraph.connectPort(&self.lpr_am_demod.block, "out1", &self.l_summer.block, "in1");
        try flowgraph.connectPort(&self.lmr_am_demod.block, "out1", &self.l_summer.block, "in2");
        try flowgraph.connectPort(&self.lpr_am_demod.block, "out1", &self.r_summer.block, "in1");
        try flowgraph.connectPort(&self.lmr_am_demod.block, "out1", &self.r_summer.block, "in2");
        try flowgraph.connect(&self.l_summer.block, &self.l_af_deemphasis.block);
        try flowgraph.connect(&self.r_summer.block, &self.r_af_deemphasis.block);

        try flowgraph.alias(&self.block, "in1", &self.fm_demod.block, "in1");
        try flowgraph.alias(&self.block, "out1", &self.l_af_deemphasis.block, "out1");
        try flowgraph.alias(&self.block, "out2", &self.r_af_deemphasis.block, "out1");
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "WBFMStereoDemodulatorBlock" {
    _ = WBFMStereoDemodulatorBlock.init(.{});
}
