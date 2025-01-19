const std = @import("std");

const radio = @import("radio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <frequency>\n", .{args[0]});
        std.posix.exit(1);
    }

    const frequency = try std.fmt.parseFloat(f64, args[1]);
    const tune_offset = -250e3;
    const deviation = 5e3;
    const bandwidth = 4e3;

    var source = radio.blocks.RtlSdrSource.init(frequency + tune_offset, 1102500, .{ .debug = true });
    var tuner = radio.blocks.TunerBlock.init(tune_offset, 2 * (deviation + bandwidth), 50);
    var fm_demod = radio.blocks.FrequencyDiscriminatorBlock.init(deviation / bandwidth);
    var af_filter = radio.blocks.LowpassFilterBlock(f32, 128).init(bandwidth, .{});
    var sink = radio.blocks.PulseAudioSink(1).init();

    var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
    defer top.deinit();
    try top.connect(&source.block, &tuner.composite);
    try top.connect(&tuner.composite, &fm_demod.block);
    try top.connect(&fm_demod.block, &af_filter.block);
    try top.connect(&af_filter.block, &sink.block);

    try top.start();
    radio.platform.waitForInterrupt();
    try top.stop();
}
