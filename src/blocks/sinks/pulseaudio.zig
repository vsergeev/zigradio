const std = @import("std");
const builtin = @import("builtin");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// libpulse-simple API
////////////////////////////////////////////////////////////////////////////////

const struct_pa_simple = opaque {};
const pa_simple = struct_pa_simple;

const PA_STREAM_PLAYBACK: c_int = 1;
const enum_pa_stream_direction = c_uint;
const pa_stream_direction_t = enum_pa_stream_direction;

const PA_SAMPLE_FLOAT32LE: c_int = 5;
const PA_SAMPLE_FLOAT32BE: c_int = 6;
const enum_pa_sample_format = c_int;
const pa_sample_format_t = enum_pa_sample_format;

const struct_pa_sample_spec = extern struct {
    format: pa_sample_format_t = @import("std").mem.zeroes(pa_sample_format_t),
    rate: u32 = @import("std").mem.zeroes(u32),
    channels: u8 = @import("std").mem.zeroes(u8),
};
const pa_sample_spec = struct_pa_sample_spec;

const struct_pa_buffer_attr = extern struct {
    maxlength: u32 = @import("std").mem.zeroes(u32),
    tlength: u32 = @import("std").mem.zeroes(u32),
    prebuf: u32 = @import("std").mem.zeroes(u32),
    minreq: u32 = @import("std").mem.zeroes(u32),
    fragsize: u32 = @import("std").mem.zeroes(u32),
};
const pa_buffer_attr = struct_pa_buffer_attr;

const enum_pa_channel_position = c_int;
const pa_channel_position_t = enum_pa_channel_position;
const struct_pa_channel_map = extern struct {
    channels: u8 = @import("std").mem.zeroes(u8),
    map: [32]pa_channel_position_t = @import("std").mem.zeroes([32]pa_channel_position_t),
};
const pa_channel_map = struct_pa_channel_map;

var pa_simple_new: *const fn (server: [*c]const u8, name: [*c]const u8, dir: pa_stream_direction_t, dev: [*c]const u8, stream_name: [*c]const u8, ss: [*c]const pa_sample_spec, map: [*c]const pa_channel_map, attr: [*c]const pa_buffer_attr, @"error": [*c]c_int) callconv(.C) ?*pa_simple = undefined;
var pa_simple_write: *const fn (s: ?*pa_simple, data: ?*const anyopaque, bytes: usize, @"error": [*c]c_int) callconv(.C) c_int = undefined;
var pa_simple_free: *const fn (s: ?*pa_simple) callconv(.C) void = undefined;
var pa_strerror: *const fn (@"error": c_int) callconv(.C) [*c]const u8 = undefined;
var pa_simple_loaded: bool = false;

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
        pa_conn: ?*pa_simple = null,
        interleaved: std.ArrayList(f32) = undefined,

        pub fn init() Self {
            return .{
                .block = Block.init(@This()),
            };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            // Open PulseAudio library
            if (!pa_simple_loaded) {
                var lib = try std.DynLib.open("libpulse-simple.so");
                pa_simple_new = lib.lookup(@TypeOf(pa_simple_new), "pa_simple_new") orelse return error.LookupFail;
                pa_simple_write = lib.lookup(@TypeOf(pa_simple_write), "pa_simple_write") orelse return error.LookupFail;
                pa_simple_free = lib.lookup(@TypeOf(pa_simple_free), "pa_simple_free") orelse return error.LookupFail;
                pa_strerror = lib.lookup(@TypeOf(pa_strerror), "pa_strerror") orelse return error.LookupFail;
                pa_simple_loaded = true;
            }

            // Prepare sample spec
            const sample_spec = pa_sample_spec{
                .format = if (builtin.target.cpu.arch.endian() == std.builtin.Endian.little) PA_SAMPLE_FLOAT32LE else PA_SAMPLE_FLOAT32BE,
                .rate = self.block.getRate(u32),
                .channels = N,
            };

            // Open PulseAudio connection
            var error_code: c_int = undefined;
            self.pa_conn = pa_simple_new(null, "ZigRadio", PA_STREAM_PLAYBACK, null, "PulseAudioSink", &sample_spec, null, null, &error_code);
            if (self.pa_conn == null) {
                std.debug.print("pa_simple_new(): {s}\n", .{pa_strerror(error_code)});
                return PulseAudioError.InitializationError;
            }

            // Allocate interleaved array
            if (N > 1) self.interleaved = std.ArrayList(f32).init(allocator);
        }

        pub fn deinitialize(self: *Self, _: std.mem.Allocator) void {
            // Free interleaved array
            if (N > 1) self.interleaved.deinit();

            // Close and free our PulseAudio connection
            if (self.pa_conn) |pa_conn| pa_simple_free(pa_conn);
        }

        pub fn _process_mono(self: *Self, x: []const f32) !ProcessResult {
            // Write to our PulseAudio connection
            var error_code: c_int = undefined;
            const ret = pa_simple_write(self.pa_conn.?, x.ptr, x.len * @sizeOf(f32), &error_code);
            if (ret < 0) {
                std.debug.print("pa_simple_write(): {s}\n", .{pa_strerror(error_code)});
                return PulseAudioError.WriteError;
            }

            return ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
        }

        pub fn _process_stereo(self: *Self, x: []const f32, y: []const f32) !ProcessResult {
            // Interleave samples
            try self.interleaved.resize(x.len * 2);
            for (x, y, 0..) |_, _, i| {
                self.interleaved.items[2 * i] = x[i];
                self.interleaved.items[2 * i + 1] = y[i];
            }

            // Write to our PulseAudio connection
            var error_code: c_int = undefined;
            const ret = pa_simple_write(self.pa_conn.?, self.interleaved.items.ptr, self.interleaved.items.len * @sizeOf(f32), &error_code);
            if (ret < 0) {
                std.debug.print("pa_simple_write(): {s}\n", .{pa_strerror(error_code)});
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
