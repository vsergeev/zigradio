const std = @import("std");

const radio = @import("radio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <frequency> <sideband>\n", .{args[0]});
        std.posix.exit(1);
    }

    const frequency = try std.fmt.parseFloat(f64, args[1]);
    const sideband: enum { LSB, USB } = if (std.mem.eql(u8, args[2], "lsb")) .LSB else .USB;
    const tune_offset = -50e3;
    const bandwidth = 3e3;

    var source = radio.blocks.RtlSdrSource.init(frequency + tune_offset, 960000, .{ .debug = true });
    var tuner = radio.blocks.TunerBlock.init(tune_offset, 2 * bandwidth, 10);
    var sb_filter = radio.blocks.ComplexBandpassFilterBlock(129).init(if (sideband == .LSB) .{ 0, -bandwidth } else .{ 0, bandwidth }, .{});
    var am_demod = radio.blocks.ComplexToRealBlock.init();
    var af_filter = radio.blocks.LowpassFilterBlock(f32, 128).init(bandwidth, .{});
    var af_gain = radio.blocks.AGCBlock(f32).init(.{ .preset = .Fast }, .{});
    var af_downsampler = radio.blocks.DownsamplerBlock(f32).init(2);
    var sink = radio.blocks.PulseAudioSink(1).init();

    var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
    defer top.deinit();
    try top.connect(&source.block, &tuner.block);
    try top.connect(&tuner.block, &sb_filter.block);
    try top.connect(&sb_filter.block, &am_demod.block);
    try top.connect(&am_demod.block, &af_filter.block);
    try top.connect(&af_filter.block, &af_gain.block);
    try top.connect(&af_gain.block, &af_downsampler.block);
    try top.connect(&af_downsampler.block, &sink.block);

    try top.start();
    radio.platform.waitForInterrupt();
    _ = try top.stop();
}
