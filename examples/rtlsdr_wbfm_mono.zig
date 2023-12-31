const std = @import("std");

const radio = @import("radio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <FM radio frequency>\n", .{args[0]});
        std.os.exit(1);
    }

    const frequency = try std.fmt.parseFloat(f64, args[1]);
    const tune_offset = -250e3;

    var source = radio.blocks.RtlSdrSource.init(frequency + tune_offset, 1102500, .{ .debug = true });
    var if_translator = radio.blocks.FrequencyTranslatorBlock.init(tune_offset);
    var if_filter = radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 128).init(100e3, .{});
    var if_downsampler = radio.blocks.DownsamplerBlock(std.math.Complex(f32)).init(5);
    var fm_demod = radio.blocks.FrequencyDiscriminatorBlock.init(1.25);
    var af_filter = radio.blocks.LowpassFilterBlock(f32, 128).init(15e3, .{});
    var af_deemphasis = radio.blocks.FMDeemphasisFilterBlock.init(75e-6);
    var af_downsampler = radio.blocks.DownsamplerBlock(f32).init(5);
    var sink = radio.blocks.PulseAudioSink(1).init();

    var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
    defer top.deinit();
    try top.connect(&source.block, &if_translator.block);
    try top.connect(&if_translator.block, &if_filter.block);
    try top.connect(&if_filter.block, &if_downsampler.block);
    try top.connect(&if_downsampler.block, &fm_demod.block);
    try top.connect(&fm_demod.block, &af_filter.block);
    try top.connect(&af_filter.block, &af_deemphasis.block);
    try top.connect(&af_deemphasis.block, &af_downsampler.block);
    try top.connect(&af_downsampler.block, &sink.block);

    try top.start();
    radio.testing.waitForInterrupt();
    try top.stop();
}
