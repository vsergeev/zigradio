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

pub fn PulseAudioSink(comptime N: comptime_int) type {
    return struct {
        const Self = @This();

        // Errors
        pub const PulseAudioError = error{
            InitializationError,
            WriteError,
        };

        block: Block,
        pa_conn: ?*pulse_simple.pa_simple = null,
        interleaved: ?std.ArrayList(f32) = null,

        pub fn init() Self {
            if (!comptime platform.hasPackage("libpulse-simple")) @compileError("Platform is missing libpulse-simple library.");
            return .{ .block = Block.init(@This()) };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            // Prepare sample spec
            const sample_spec = pulse_simple.pa_sample_spec{
                .format = if (builtin.target.cpu.arch.endian() == std.builtin.Endian.Little) pulse_simple.PA_SAMPLE_FLOAT32LE else pulse_simple.PA_SAMPLE_FLOAT32BE,
                .rate = try self.block.getRate(u32),
                .channels = N,
            };

            // Open PulseAudio connection
            var error_code: c_int = undefined;
            self.pa_conn = pulse_simple.pa_simple_new(null, "ZigRadio", pulse_simple.PA_STREAM_PLAYBACK, null, "PulseAudioSink", &sample_spec, null, null, &error_code);
            if (self.pa_conn == null) {
                std.debug.print("pa_simple_new(): {s}\n", .{pulse_simple.pa_strerror(error_code)});
                return PulseAudioError.InitializationError;
            }

            // Allocate interleaved array
            if (N > 1) self.interleaved = std.ArrayList(f32).init(allocator);
        }

        pub fn deinitialize(self: *Self, _: std.mem.Allocator) void {
            // Free interleaved array
            if (N > 1) self.interleaved.?.deinit();

            // Close and free our PulseAudio connection
            if (self.pa_conn) |pa_conn| pulse_simple.pa_simple_free(pa_conn);
        }

        pub fn _process_mono(self: *Self, x: []const f32) !ProcessResult {
            // Write to our PulseAudio connection
            var error_code: c_int = undefined;
            const ret = pulse_simple.pa_simple_write(self.pa_conn.?, x.ptr, x.len * @sizeOf(f32), &error_code);
            if (ret < 0) {
                std.debug.print("pa_simple_write(): {s}\n", .{pulse_simple.pa_strerror(error_code)});
                return PulseAudioError.WriteError;
            }

            return ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
        }

        pub fn _process_stereo(self: *Self, x: []const f32, y: []const f32) !ProcessResult {
            // Interleave samples
            try self.interleaved.?.resize(x.len * 2);
            for (x, y, 0..) |_, _, i| {
                self.interleaved.?.items[2 * i] = x[i];
                self.interleaved.?.items[2 * i + 1] = y[i];
            }

            // Write to our PulseAudio connection
            var error_code: c_int = undefined;
            const ret = pulse_simple.pa_simple_write(self.pa_conn.?, self.interleaved.?.items.ptr, self.interleaved.?.items.len * @sizeOf(f32), &error_code);
            if (ret < 0) {
                std.debug.print("pa_simple_write(): {s}\n", .{pulse_simple.pa_strerror(error_code)});
                return PulseAudioError.WriteError;
            }

            return ProcessResult.init(&[2]usize{ x.len, y.len }, &[0]usize{});
        }

        pub const process = switch (N) {
            1 => _process_mono,
            2 => _process_stereo,
            else => @compileError("Only one or two channels supported."),
        };
    };
}
