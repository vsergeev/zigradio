const std = @import("std");

const CompositeBlock = @import("../../radio.zig").CompositeBlock;
const Flowgraph = @import("../../radio.zig").Flowgraph;

const FrequencyTranslatorBlock = @import("../signal/frequencytranslator.zig").FrequencyTranslatorBlock;
const LowpassFilterBlock = @import("../signal/lowpassfilter.zig").LowpassFilterBlock;
const DownsamplerBlock = @import("../signal/downsampler.zig").DownsamplerBlock;

////////////////////////////////////////////////////////////////////////////////
// Tuner Block
////////////////////////////////////////////////////////////////////////////////

pub const TunerBlock = struct {
    block: CompositeBlock,
    translator: FrequencyTranslatorBlock,
    filter: LowpassFilterBlock(std.math.Complex(f32), 64),
    downsampler: DownsamplerBlock(std.math.Complex(f32)),

    pub fn init(offset: f32, cutoff: f32, factor: usize) TunerBlock {
        return .{
            .block = CompositeBlock.init(@This(), &.{"in1"}, &.{"out1"}),
            .translator = FrequencyTranslatorBlock.init(offset),
            .filter = LowpassFilterBlock(std.math.Complex(f32), 64).init(cutoff, .{}),
            .downsampler = DownsamplerBlock(std.math.Complex(f32)).init(factor),
        };
    }

    pub fn connect(self: *TunerBlock, flowgraph: *Flowgraph) !void {
        try flowgraph.connect(&self.translator.block, &self.filter.block);
        try flowgraph.connect(&self.filter.block, &self.downsampler.block);

        try flowgraph.alias(&self.block, "in1", &self.translator.block, "in1");
        try flowgraph.alias(&self.block, "out1", &self.downsampler.block, "out1");
    }
};
