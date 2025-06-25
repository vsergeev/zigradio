// @block FMDeemphasisFilterBlock
// @description Filter a complex or real valued signal with an FM De-emphasis
// filter, a single-pole low-pass IIR filter.
//
// $$ y[n] = (x * h_{fmdeemph})[n] $$
//
// @category Filtering
// @param tau De-emphasis time constant
// @signature in:f32 > out:f32
// @usage
// var deemphasis = radio.blocks.FMDeemphasisFilterBlock.init(75e-6);

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const SinglepoleLowpassFilterBlock = @import("./singlepolelowpassfilter.zig").SinglepoleLowpassFilterBlock;

////////////////////////////////////////////////////////////////////////////////
// FM Deemphasis Filter Block
////////////////////////////////////////////////////////////////////////////////

pub const FMDeemphasisFilterBlock = struct {
    pub fn init(tau: f32) SinglepoleLowpassFilterBlock(f32) {
        return SinglepoleLowpassFilterBlock(f32).init(1 / (2 * std.math.pi * tau));
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/fmdeemphasisfilter.zig");

test "FMDeemphasisFilterBlock" {
    // 5e-6 tau, Float32
    {
        var block = FMDeemphasisFilterBlock.init(5e-6);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_tau_5em6}, .{});
    }

    // 1e-6 tau, Float32
    {
        var block = FMDeemphasisFilterBlock.init(1e-6);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_tau_1em6}, .{});
    }
}
