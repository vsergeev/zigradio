const std = @import("std");

const radio = @import("radio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <FM radio frequency>\n", .{args[0]});
        std.posix.exit(1);
    }

    const frequency = try std.fmt.parseFloat(f64, args[1]);
    const tune_offset = -250e3;

    var source = radio.blocks.RtlSdrSource.init(frequency + tune_offset, 960000, .{ .debug = true });
    var tuner = radio.blocks.TunerBlock.init(tune_offset, 200e3, 4);
    var fm_demod = radio.blocks.FrequencyDiscriminatorBlock.init(75e3);
    var real_to_complex = radio.blocks.RealToComplexBlock.init();
    var delay = radio.blocks.DelayBlock(std.math.Complex(f32)).init(129);
    var pilot_filter = radio.blocks.ComplexBandpassFilterBlock(129).init(.{ 18e3, 20e3 }, .{});
    var pilot_pll = radio.blocks.ComplexPLLBlock.init(500, .{ 19e3 - 100, 19e3 + 100 }, .{ .multiplier = 2 });
    var mixer = radio.blocks.MultiplyConjugateBlock.init();
    // L+R
    var lpr_filter = radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 128).init(15e3, .{});
    var lpr_am_demod = radio.blocks.ComplexToRealBlock.init();
    // L-R
    var lmr_filter = radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 128).init(15e3, .{});
    var lmr_am_demod = radio.blocks.ComplexToRealBlock.init();
    // L
    var l_summer = radio.blocks.AddBlock(f32).init();
    var l_af_deemphasis = radio.blocks.FMDeemphasisFilterBlock.init(75e-6);
    var l_af_downsampler = radio.blocks.DownsamplerBlock(f32).init(5);
    // R
    var r_summer = radio.blocks.SubtractBlock(f32).init();
    var r_af_deemphasis = radio.blocks.FMDeemphasisFilterBlock.init(75e-6);
    var r_af_downsampler = radio.blocks.DownsamplerBlock(f32).init(5);
    var sink = radio.blocks.PulseAudioSink(2).init();

    var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
    defer top.deinit();
    try top.connect(&source.block, &tuner.block);
    try top.connect(&tuner.block, &fm_demod.block);
    try top.connect(&fm_demod.block, &real_to_complex.block);
    try top.connect(&real_to_complex.block, &pilot_filter.block);
    try top.connect(&real_to_complex.block, &delay.block);
    try top.connect(&pilot_filter.block, &pilot_pll.block);
    try top.connectPort(&delay.block, "out1", &mixer.block, "in1");
    try top.connectPort(&pilot_pll.block, "out1", &mixer.block, "in2");
    try top.connect(&delay.block, &lpr_filter.block);
    try top.connect(&mixer.block, &lmr_filter.block);
    try top.connect(&lpr_filter.block, &lpr_am_demod.block);
    try top.connect(&lmr_filter.block, &lmr_am_demod.block);
    try top.connectPort(&lpr_am_demod.block, "out1", &l_summer.block, "in1");
    try top.connectPort(&lmr_am_demod.block, "out1", &l_summer.block, "in2");
    try top.connectPort(&lpr_am_demod.block, "out1", &r_summer.block, "in1");
    try top.connectPort(&lmr_am_demod.block, "out1", &r_summer.block, "in2");
    try top.connect(&l_summer.block, &l_af_deemphasis.block);
    try top.connect(&l_af_deemphasis.block, &l_af_downsampler.block);
    try top.connect(&r_summer.block, &r_af_deemphasis.block);
    try top.connect(&r_af_deemphasis.block, &r_af_downsampler.block);
    try top.connectPort(&l_af_downsampler.block, "out1", &sink.block, "in1");
    try top.connectPort(&r_af_downsampler.block, "out1", &sink.block, "in2");

    try top.start();
    radio.platform.waitForInterrupt();
    _ = try top.stop();
}
