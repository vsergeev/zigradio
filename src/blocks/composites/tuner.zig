// @block TunerBlock
// @description Frequency translate, low-pass filter, and downsample a
// complex-valued signal.
//
// $$ y[n] = (\text{FrequencyTranslate}(x[n], f_{offset}) * h_{lpf})[nM] $$
//
// This block is convenient for translating signals to baseband.
// @category Spectrum Manipulation
// @param offset f32 Translation offset in Hz
// @param bandwidth f32 Signal bandwidth in Hz
// @param factor usize Downsampling factor M
// @signature in1:Complex(f32) > out1:Complex(f32)
// @usage
// var tuner = radio.blocks.TunerBlock.init(50e3, 10e3, 5);
// try top.connect(&src.block, &tuner.block);
// try top.connect(&tuner.block, &snk.block);

const std = @import("std");

const radio = @import("../../radio.zig");

////////////////////////////////////////////////////////////////////////////////
// Tuner Block
////////////////////////////////////////////////////////////////////////////////

pub const TunerBlock = struct {
    block: radio.CompositeBlock,
    translator: radio.blocks.FrequencyTranslatorBlock,
    filter: radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 64),
    downsampler: radio.blocks.DownsamplerBlock(std.math.Complex(f32)),

    pub fn init(offset: f32, bandwidth: f32, factor: usize) TunerBlock {
        return .{
            .block = radio.CompositeBlock.init(@This(), &.{"in1"}, &.{"out1"}),
            .translator = radio.blocks.FrequencyTranslatorBlock.init(offset),
            .filter = radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 64).init(bandwidth / 2, .{}),
            .downsampler = radio.blocks.DownsamplerBlock(std.math.Complex(f32)).init(factor),
        };
    }

    pub fn connect(self: *TunerBlock, flowgraph: *radio.Flowgraph) !void {
        try flowgraph.connect(&self.translator.block, &self.filter.block);
        try flowgraph.connect(&self.filter.block, &self.downsampler.block);

        try flowgraph.alias(&self.block, "in1", &self.translator.block, "in1");
        try flowgraph.alias(&self.block, "out1", &self.downsampler.block, "out1");
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "TunerBlock" {
    _ = TunerBlock.init(50e3, 10e3, 5);
}
