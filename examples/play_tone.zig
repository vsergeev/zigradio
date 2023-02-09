const std = @import("std");

const radio = @import("radio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var source = radio.blocks.SignalSource.init(radio.blocks.SignalSource.WaveformFunction.Cosine, 440, 44100, .{});
    var sink = radio.blocks.PulseAudioSink.init();

    var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
    defer top.deinit();
    try top.connect(&source.block, &sink.block);

    try top.start();
    radio.testing.waitForInterrupt();
    try top.stop();
}
