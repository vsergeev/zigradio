// Pull in all tests
test {
    @import("std").testing.refAllDecls(@This());
}

pub const PrintSink = @import("print.zig").PrintSink;
pub const BenchmarkSink = @import("benchmark.zig").BenchmarkSink;
pub const ApplicationSink = @import("application.zig").ApplicationSink;
pub const IQStreamSink = @import("iqstream.zig").IQStreamSink;
pub const RealStreamSink = @import("realstream.zig").RealStreamSink;
pub const JSONStreamSink = @import("jsonstream.zig").JSONStreamSink;
pub const PulseAudioSink = @import("pulseaudio.zig").PulseAudioSink;
