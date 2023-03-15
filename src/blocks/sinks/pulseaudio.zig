const std = @import("std");
const builtin = @import("builtin");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;
const pulse_simple = @cImport({
    @cInclude("pulse/simple.h");
    @cInclude("pulse/error.h");
});

////////////////////////////////////////////////////////////////////////////////
// PulseAudio Sink
////////////////////////////////////////////////////////////////////////////////

pub const PulseAudioSink = struct {
    // Errors
    pub const PulseAudioError = error{
        InitializationError,
        WriteError,
    };

    block: Block,
    pa_conn: ?*pulse_simple.pa_simple = null,

    pub fn init() PulseAudioSink {
        if (!comptime platform.hasPackage("libpulse-simple")) @compileError("Platform is missing libpulse-simple library.");
        return .{ .block = Block.init(@This()) };
    }

    pub fn initialize(self: *PulseAudioSink, _: std.mem.Allocator) !void {
        // Prepare sample spec
        const sample_spec = pulse_simple.pa_sample_spec{
            .format = if (builtin.target.cpu.arch.endian() == std.builtin.Endian.Little) pulse_simple.PA_SAMPLE_FLOAT32LE else pulse_simple.PA_SAMPLE_FLOAT32BE,
            .rate = try self.block.getRate(u32),
            .channels = 1,
        };

        // Open PulseAudio connection
        var error_code: c_int = undefined;
        self.pa_conn = pulse_simple.pa_simple_new(null, "ZigRadio", pulse_simple.PA_STREAM_PLAYBACK, null, "PulseAudioSink", &sample_spec, null, null, &error_code);
        if (self.pa_conn == null) {
            std.debug.print("pa_simple_new(): {s}\n", .{pulse_simple.pa_strerror(error_code)});
            return PulseAudioError.InitializationError;
        }
    }

    pub fn deinitialize(self: *PulseAudioSink, _: std.mem.Allocator) void {
        // Close and free our PulseAudio connection
        if (self.pa_conn) |pa_conn| pulse_simple.pa_simple_free(pa_conn);
    }

    pub fn process(self: *PulseAudioSink, x: []const f32) !ProcessResult {
        // Write to our PulseAudio connection
        var error_code: c_int = undefined;
        const ret = pulse_simple.pa_simple_write(self.pa_conn.?, x.ptr, x.len * @sizeOf(f32), &error_code);
        if (ret < 0) {
            std.debug.print("pa_simple_write(): {s}\n", .{pulse_simple.pa_strerror(error_code)});
            return PulseAudioError.WriteError;
        }

        return ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
    }
};
