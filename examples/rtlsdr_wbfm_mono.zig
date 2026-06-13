const std = @import("std");

const radio = @import("radio");

pub fn main(init: std.process.Init) !void {
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    const prog = args_it.next() orelse "example";
    const frequency_arg = args_it.next();
    if (frequency_arg == null) {
        std.debug.print("Usage: {s} <FM radio frequency>\n", .{prog});
        std.process.exit(1);
    }

    const frequency = try std.fmt.parseFloat(f64, frequency_arg.?);
    const tune_offset = -250e3;

    var source = radio.blocks.RtlSdrSource.init(frequency + tune_offset, 960000, .{ .debug = true });
    var tuner = radio.blocks.TunerBlock.init(tune_offset, 200e3, 4);
    var fm_demod = radio.blocks.FrequencyDiscriminatorBlock.init(75e3);
    var af_filter = radio.blocks.LowpassFilterBlock(f32, 128).init(15e3, .{});
    var af_deemphasis = radio.blocks.FMDeemphasisFilterBlock.init(75e-6);
    var af_downsampler = radio.blocks.DownsamplerBlock(f32).init(5);
    var sink = radio.blocks.PulseAudioSink(1).init();

    var top = radio.Flowgraph.init(init.gpa, .{ .debug = true });
    defer top.deinit();
    try top.connect(&source.block, &tuner.block);
    try top.connect(&tuner.block, &fm_demod.block);
    try top.connect(&fm_demod.block, &af_filter.block);
    try top.connect(&af_filter.block, &af_deemphasis.block);
    try top.connect(&af_deemphasis.block, &af_downsampler.block);
    try top.connect(&af_downsampler.block, &sink.block);

    try top.start();
    radio.platform.waitForInterrupt();
    _ = try top.stop();
}
