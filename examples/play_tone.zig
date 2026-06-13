const std = @import("std");

const radio = @import("radio");

pub fn main(init: std.process.Init) !void {
    var source = radio.blocks.SignalSource.init(radio.blocks.SignalSource.WaveformFunction.Cosine, 440, 44100, .{});
    var sink = radio.blocks.PulseAudioSink(1).init();

    var top = radio.Flowgraph.init(init.gpa, .{ .debug = true });
    defer top.deinit();
    try top.connect(&source.block, &sink.block);

    try top.start();
    radio.platform.waitForInterrupt();
    _ = try top.stop();
}
