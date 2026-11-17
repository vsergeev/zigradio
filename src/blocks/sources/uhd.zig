// @block UHDSource
// @description Source a complex-valued signal from a USRP. This source
// requires the libuhd library.
// @category Sources
// @param frequency f64 Tuning frequency in Hz
// @param rate f64 Sample rate in Hz
// @param options Options Additional options:
//      * `device_address` (`[:0]const u8`, default "" for first available device, e.g. "type=b200")
//      * `channel` (`usize`, default 0)
//      * `gain` (`?f64`, number in dB for manual overall gain, default null for
//                 auto-gain when no gain elements are specified)
//      * `gains` (`?[]const Gain`, gain element name and value in dB pairs for
//                  manual gain, default null)
//      * `bandwidth` (`?f64`, default null for device default)
//      * `antenna` (`?[:0]const u8`, default null for device default, e.g. "RX2")
//      * `debug` (`bool`, default false)
// @signature > out1:Complex(f32)
// @usage
// var src = radio.blocks.UHDSource.init(91.1e6, 1e6, .{ .device_address = "type=b200", .gain = 45 });
// try top.connect(&src.block, &snk.block);

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// libuhd API
////////////////////////////////////////////////////////////////////////////////

const struct_uhd_usrp = opaque {};
const struct_uhd_rx_streamer = opaque {};
const struct_uhd_rx_metadata_t = opaque {};
const uhd_usrp_handle = ?*struct_uhd_usrp;
const uhd_rx_streamer_handle = ?*struct_uhd_rx_streamer;
const struct_uhd_meta_range_t = opaque {};
const struct_uhd_string_vector_t = opaque {};
const uhd_rx_metadata_handle = ?*struct_uhd_rx_metadata_t;
const uhd_meta_range_handle = ?*struct_uhd_meta_range_t;
const uhd_string_vector_handle = ?*struct_uhd_string_vector_t;

const uhd_error = c_int;

const uhd_tune_request_policy_t = c_int;
const UHD_TUNE_REQUEST_POLICY_AUTO: uhd_tune_request_policy_t = 65;

const uhd_tune_request_t = extern struct {
    target_freq: f64,
    rf_freq_policy: uhd_tune_request_policy_t,
    rf_freq: f64,
    dsp_freq_policy: uhd_tune_request_policy_t,
    dsp_freq: f64,
    args: [*c]u8,
};

const uhd_tune_result_t = extern struct {
    clipped_rf_freq: f64,
    target_rf_freq: f64,
    actual_rf_freq: f64,
    target_dsp_freq: f64,
    actual_dsp_freq: f64,
};

const uhd_stream_args_t = extern struct {
    cpu_format: [*c]u8,
    otw_format: [*c]u8,
    args: [*c]u8,
    channel_list: [*c]usize,
    n_channels: c_int,
};

const uhd_stream_mode_t = c_int;
const UHD_STREAM_MODE_START_CONTINUOUS: uhd_stream_mode_t = 97;
const UHD_STREAM_MODE_STOP_CONTINUOUS: uhd_stream_mode_t = 111;

const uhd_stream_cmd_t = extern struct {
    stream_mode: uhd_stream_mode_t,
    num_samps: usize,
    stream_now: bool,
    time_spec_full_secs: i64,
    time_spec_frac_secs: f64,
};

const uhd_rx_metadata_error_code_t = c_int;
const UHD_RX_METADATA_ERROR_CODE_NONE: uhd_rx_metadata_error_code_t = 0x0;
const UHD_RX_METADATA_ERROR_CODE_OVERFLOW: uhd_rx_metadata_error_code_t = 0x8;

var uhd_get_last_error: *const fn (error_out: [*c]u8, strbuffer_len: usize) callconv(.c) uhd_error = undefined;
var uhd_usrp_make: *const fn (h: [*c]uhd_usrp_handle, args: [*c]const u8) callconv(.c) uhd_error = undefined;
var uhd_usrp_free: *const fn (h: [*c]uhd_usrp_handle) callconv(.c) uhd_error = undefined;
var uhd_rx_streamer_make: *const fn (h: [*c]uhd_rx_streamer_handle) callconv(.c) uhd_error = undefined;
var uhd_rx_streamer_free: *const fn (h: [*c]uhd_rx_streamer_handle) callconv(.c) uhd_error = undefined;
var uhd_rx_metadata_make: *const fn (handle: [*c]uhd_rx_metadata_handle) callconv(.c) uhd_error = undefined;
var uhd_rx_metadata_free: *const fn (handle: [*c]uhd_rx_metadata_handle) callconv(.c) uhd_error = undefined;
var uhd_usrp_set_rx_antenna: *const fn (h: uhd_usrp_handle, ant: [*c]const u8, chan: usize) callconv(.c) uhd_error = undefined;
var uhd_usrp_set_rx_rate: *const fn (h: uhd_usrp_handle, rate: f64, chan: usize) callconv(.c) uhd_error = undefined;
var uhd_usrp_get_rx_rate: *const fn (h: uhd_usrp_handle, chan: usize, rate_out: [*c]f64) callconv(.c) uhd_error = undefined;
var uhd_usrp_set_rx_bandwidth: *const fn (h: uhd_usrp_handle, bandwidth: f64, chan: usize) callconv(.c) uhd_error = undefined;
var uhd_usrp_get_rx_bandwidth: *const fn (h: uhd_usrp_handle, chan: usize, bandwidth_out: [*c]f64) callconv(.c) uhd_error = undefined;
var uhd_usrp_set_rx_agc: *const fn (h: uhd_usrp_handle, enable: bool, chan: usize) callconv(.c) uhd_error = undefined;
var uhd_usrp_set_rx_gain: *const fn (h: uhd_usrp_handle, gain: f64, chan: usize, gain_name: [*c]const u8) callconv(.c) uhd_error = undefined;
var uhd_usrp_get_rx_gain: *const fn (h: uhd_usrp_handle, chan: usize, gain_name: [*c]const u8, gain_out: [*c]f64) callconv(.c) uhd_error = undefined;
var uhd_usrp_set_rx_freq: *const fn (h: uhd_usrp_handle, tune_request: [*c]uhd_tune_request_t, chan: usize, tune_result: [*c]uhd_tune_result_t) callconv(.c) uhd_error = undefined;
var uhd_usrp_get_rx_freq: *const fn (h: uhd_usrp_handle, chan: usize, freq_out: [*c]f64) callconv(.c) uhd_error = undefined;
var uhd_usrp_get_rx_stream: *const fn (h: uhd_usrp_handle, stream_args: [*c]uhd_stream_args_t, h_out: uhd_rx_streamer_handle) callconv(.c) uhd_error = undefined;
var uhd_rx_streamer_max_num_samps: *const fn (h: uhd_rx_streamer_handle, max_num_samps_out: [*c]usize) callconv(.c) uhd_error = undefined;
var uhd_rx_streamer_issue_stream_cmd: *const fn (h: uhd_rx_streamer_handle, stream_cmd: [*c]const uhd_stream_cmd_t) callconv(.c) uhd_error = undefined;
var uhd_rx_streamer_recv: *const fn (h: uhd_rx_streamer_handle, buffs: [*c]?*anyopaque, samps_per_buff: usize, md: [*c]uhd_rx_metadata_handle, timeout: f64, one_packet: bool, items_recvd: [*c]usize) callconv(.c) uhd_error = undefined;
var uhd_rx_metadata_error_code: *const fn (h: uhd_rx_metadata_handle, error_code_out: [*c]uhd_rx_metadata_error_code_t) callconv(.c) uhd_error = undefined;
var uhd_get_version_string: *const fn (version_out: [*c]u8, buffer_len: usize) callconv(.c) uhd_error = undefined;
var uhd_get_abi_string: *const fn (abi_string_out: [*c]u8, buffer_len: usize) callconv(.c) uhd_error = undefined;
var uhd_meta_range_make: *const fn (h: [*c]uhd_meta_range_handle) callconv(.c) uhd_error = undefined;
var uhd_meta_range_free: *const fn (h: [*c]uhd_meta_range_handle) callconv(.c) uhd_error = undefined;
var uhd_meta_range_start: *const fn (h: uhd_meta_range_handle, start_out: [*c]f64) callconv(.c) uhd_error = undefined;
var uhd_meta_range_stop: *const fn (h: uhd_meta_range_handle, stop_out: [*c]f64) callconv(.c) uhd_error = undefined;
var uhd_string_vector_make: *const fn (h: [*c]uhd_string_vector_handle) callconv(.c) uhd_error = undefined;
var uhd_string_vector_free: *const fn (h: [*c]uhd_string_vector_handle) callconv(.c) uhd_error = undefined;
var uhd_string_vector_at: *const fn (h: uhd_string_vector_handle, index: usize, value_out: [*c]u8, strbuffer_len: usize) callconv(.c) uhd_error = undefined;
var uhd_string_vector_size: *const fn (h: uhd_string_vector_handle, size_out: [*c]usize) callconv(.c) uhd_error = undefined;
var uhd_usrp_get_rx_num_channels: *const fn (h: uhd_usrp_handle, num_channels_out: [*c]usize) callconv(.c) uhd_error = undefined;
var uhd_usrp_get_rx_rates: *const fn (h: uhd_usrp_handle, chan: usize, rates_out: uhd_meta_range_handle) callconv(.c) uhd_error = undefined;
var uhd_usrp_get_rx_freq_range: *const fn (h: uhd_usrp_handle, chan: usize, freq_range_out: uhd_meta_range_handle) callconv(.c) uhd_error = undefined;
var uhd_usrp_get_rx_bandwidth_range: *const fn (h: uhd_usrp_handle, chan: usize, bandwidth_range_out: uhd_meta_range_handle) callconv(.c) uhd_error = undefined;
var uhd_usrp_get_rx_gain_range: *const fn (h: uhd_usrp_handle, name: [*c]const u8, chan: usize, gain_range_out: uhd_meta_range_handle) callconv(.c) uhd_error = undefined;
var uhd_usrp_get_rx_gain_names: *const fn (h: uhd_usrp_handle, chan: usize, gain_names_out: [*c]uhd_string_vector_handle) callconv(.c) uhd_error = undefined;
var uhd_usrp_get_rx_antennas: *const fn (h: uhd_usrp_handle, chan: usize, antennas_out: [*c]uhd_string_vector_handle) callconv(.c) uhd_error = undefined;
var uhd_loaded: bool = false;

////////////////////////////////////////////////////////////////////////////////
// UHD Source
////////////////////////////////////////////////////////////////////////////////

pub const UHDSource = struct {
    // Gain Element
    pub const Gain = struct {
        name: [:0]const u8,
        value: f64,
    };

    // Options
    pub const Options = struct {
        device_address: [:0]const u8 = "",
        channel: usize = 0,
        gain: ?f64 = null,
        gains: ?[]const Gain = null,
        bandwidth: ?f64 = null,
        antenna: ?[:0]const u8 = null,
        debug: bool = false,
    };

    // Errors
    pub const UHDError = error{
        InitializationError,
        ReadError,
    };

    // Constants
    const RECV_TIMEOUT = 3.0;

    block: Block,

    // Configuration
    frequency: f64,
    rate: f64,
    options: Options,

    // State
    usrp: uhd_usrp_handle = null,
    rx_streamer: uhd_rx_streamer_handle = null,
    rx_metadata: uhd_rx_metadata_handle = null,
    chunk_size: usize = 0,
    streaming: bool = false,

    pub fn init(frequency: f64, rate: f64, options: Options) UHDSource {
        return .{ .block = Block.init(@This()), .frequency = frequency, .rate = rate, .options = options };
    }

    pub fn setRate(self: *UHDSource, _: f64) !f64 {
        return self.rate;
    }

    pub fn initialize(self: *UHDSource, _: std.mem.Allocator, _: std.Io) !void {
        // Open libuhd library
        if (!uhd_loaded) {
            var lib = try std.DynLib.open("libuhd.so");
            uhd_get_last_error = lib.lookup(@TypeOf(uhd_get_last_error), "uhd_get_last_error") orelse return error.LookupFail;
            uhd_usrp_make = lib.lookup(@TypeOf(uhd_usrp_make), "uhd_usrp_make") orelse return error.LookupFail;
            uhd_usrp_free = lib.lookup(@TypeOf(uhd_usrp_free), "uhd_usrp_free") orelse return error.LookupFail;
            uhd_rx_streamer_make = lib.lookup(@TypeOf(uhd_rx_streamer_make), "uhd_rx_streamer_make") orelse return error.LookupFail;
            uhd_rx_streamer_free = lib.lookup(@TypeOf(uhd_rx_streamer_free), "uhd_rx_streamer_free") orelse return error.LookupFail;
            uhd_rx_metadata_make = lib.lookup(@TypeOf(uhd_rx_metadata_make), "uhd_rx_metadata_make") orelse return error.LookupFail;
            uhd_rx_metadata_free = lib.lookup(@TypeOf(uhd_rx_metadata_free), "uhd_rx_metadata_free") orelse return error.LookupFail;
            uhd_usrp_set_rx_antenna = lib.lookup(@TypeOf(uhd_usrp_set_rx_antenna), "uhd_usrp_set_rx_antenna") orelse return error.LookupFail;
            uhd_usrp_set_rx_rate = lib.lookup(@TypeOf(uhd_usrp_set_rx_rate), "uhd_usrp_set_rx_rate") orelse return error.LookupFail;
            uhd_usrp_get_rx_rate = lib.lookup(@TypeOf(uhd_usrp_get_rx_rate), "uhd_usrp_get_rx_rate") orelse return error.LookupFail;
            uhd_usrp_set_rx_bandwidth = lib.lookup(@TypeOf(uhd_usrp_set_rx_bandwidth), "uhd_usrp_set_rx_bandwidth") orelse return error.LookupFail;
            uhd_usrp_get_rx_bandwidth = lib.lookup(@TypeOf(uhd_usrp_get_rx_bandwidth), "uhd_usrp_get_rx_bandwidth") orelse return error.LookupFail;
            uhd_usrp_set_rx_agc = lib.lookup(@TypeOf(uhd_usrp_set_rx_agc), "uhd_usrp_set_rx_agc") orelse return error.LookupFail;
            uhd_usrp_set_rx_gain = lib.lookup(@TypeOf(uhd_usrp_set_rx_gain), "uhd_usrp_set_rx_gain") orelse return error.LookupFail;
            uhd_usrp_get_rx_gain = lib.lookup(@TypeOf(uhd_usrp_get_rx_gain), "uhd_usrp_get_rx_gain") orelse return error.LookupFail;
            uhd_usrp_set_rx_freq = lib.lookup(@TypeOf(uhd_usrp_set_rx_freq), "uhd_usrp_set_rx_freq") orelse return error.LookupFail;
            uhd_usrp_get_rx_freq = lib.lookup(@TypeOf(uhd_usrp_get_rx_freq), "uhd_usrp_get_rx_freq") orelse return error.LookupFail;
            uhd_usrp_get_rx_stream = lib.lookup(@TypeOf(uhd_usrp_get_rx_stream), "uhd_usrp_get_rx_stream") orelse return error.LookupFail;
            uhd_rx_streamer_max_num_samps = lib.lookup(@TypeOf(uhd_rx_streamer_max_num_samps), "uhd_rx_streamer_max_num_samps") orelse return error.LookupFail;
            uhd_rx_streamer_issue_stream_cmd = lib.lookup(@TypeOf(uhd_rx_streamer_issue_stream_cmd), "uhd_rx_streamer_issue_stream_cmd") orelse return error.LookupFail;
            uhd_rx_streamer_recv = lib.lookup(@TypeOf(uhd_rx_streamer_recv), "uhd_rx_streamer_recv") orelse return error.LookupFail;
            uhd_rx_metadata_error_code = lib.lookup(@TypeOf(uhd_rx_metadata_error_code), "uhd_rx_metadata_error_code") orelse return error.LookupFail;
            uhd_get_version_string = lib.lookup(@TypeOf(uhd_get_version_string), "uhd_get_version_string") orelse return error.LookupFail;
            uhd_get_abi_string = lib.lookup(@TypeOf(uhd_get_abi_string), "uhd_get_abi_string") orelse return error.LookupFail;
            uhd_meta_range_make = lib.lookup(@TypeOf(uhd_meta_range_make), "uhd_meta_range_make") orelse return error.LookupFail;
            uhd_meta_range_free = lib.lookup(@TypeOf(uhd_meta_range_free), "uhd_meta_range_free") orelse return error.LookupFail;
            uhd_meta_range_start = lib.lookup(@TypeOf(uhd_meta_range_start), "uhd_meta_range_start") orelse return error.LookupFail;
            uhd_meta_range_stop = lib.lookup(@TypeOf(uhd_meta_range_stop), "uhd_meta_range_stop") orelse return error.LookupFail;
            uhd_string_vector_make = lib.lookup(@TypeOf(uhd_string_vector_make), "uhd_string_vector_make") orelse return error.LookupFail;
            uhd_string_vector_free = lib.lookup(@TypeOf(uhd_string_vector_free), "uhd_string_vector_free") orelse return error.LookupFail;
            uhd_string_vector_at = lib.lookup(@TypeOf(uhd_string_vector_at), "uhd_string_vector_at") orelse return error.LookupFail;
            uhd_string_vector_size = lib.lookup(@TypeOf(uhd_string_vector_size), "uhd_string_vector_size") orelse return error.LookupFail;
            uhd_usrp_get_rx_num_channels = lib.lookup(@TypeOf(uhd_usrp_get_rx_num_channels), "uhd_usrp_get_rx_num_channels") orelse return error.LookupFail;
            uhd_usrp_get_rx_rates = lib.lookup(@TypeOf(uhd_usrp_get_rx_rates), "uhd_usrp_get_rx_rates") orelse return error.LookupFail;
            uhd_usrp_get_rx_freq_range = lib.lookup(@TypeOf(uhd_usrp_get_rx_freq_range), "uhd_usrp_get_rx_freq_range") orelse return error.LookupFail;
            uhd_usrp_get_rx_bandwidth_range = lib.lookup(@TypeOf(uhd_usrp_get_rx_bandwidth_range), "uhd_usrp_get_rx_bandwidth_range") orelse return error.LookupFail;
            uhd_usrp_get_rx_gain_range = lib.lookup(@TypeOf(uhd_usrp_get_rx_gain_range), "uhd_usrp_get_rx_gain_range") orelse return error.LookupFail;
            uhd_usrp_get_rx_gain_names = lib.lookup(@TypeOf(uhd_usrp_get_rx_gain_names), "uhd_usrp_get_rx_gain_names") orelse return error.LookupFail;
            uhd_usrp_get_rx_antennas = lib.lookup(@TypeOf(uhd_usrp_get_rx_antennas), "uhd_usrp_get_rx_antennas") orelse return error.LookupFail;
            uhd_loaded = true;
        }

        self.usrp = null;
        self.rx_streamer = null;
        self.rx_metadata = null;
        self.chunk_size = 0;
        self.streaming = false;

        // Dump version info
        if (self.options.debug) {
            var uhd_version: [512:0]u8 = @splat(0);
            var abi_version: [512:0]u8 = @splat(0);
            _ = uhd_get_version_string(&uhd_version, uhd_version.len);
            _ = uhd_get_abi_string(&abi_version, abi_version.len);

            std.debug.print("[UHDSource] UHD version:      {s}\n", .{std.mem.sliceTo(&uhd_version, 0)});
            std.debug.print("[UHDSource] UHD ABI version:  {s}\n", .{std.mem.sliceTo(&abi_version, 0)});
        }

        // Open device
        var ret = uhd_usrp_make(&self.usrp, self.options.device_address);
        if (ret != 0) {
            printLastError("uhd_usrp_make()");
            return UHDError.InitializationError;
        }

        // Create RX streamer
        ret = uhd_rx_streamer_make(&self.rx_streamer);
        if (ret != 0) {
            printLastError("uhd_rx_streamer_make()");
            return UHDError.InitializationError;
        }

        // Create RX metadata
        ret = uhd_rx_metadata_make(&self.rx_metadata);
        if (ret != 0) {
            printLastError("uhd_rx_metadata_make()");
            return UHDError.InitializationError;
        }

        // Dump device info
        if (self.options.debug) {
            // Create range and string vector objects for lookups
            var range: uhd_meta_range_handle = null;
            ret = uhd_meta_range_make(&range);
            if (ret != 0) {
                printLastError("uhd_meta_range_make()");
                return UHDError.InitializationError;
            }
            defer _ = uhd_meta_range_free(&range);

            var strings: uhd_string_vector_handle = null;
            ret = uhd_string_vector_make(&strings);
            if (ret != 0) {
                printLastError("uhd_string_vector_make()");
                return UHDError.InitializationError;
            }
            defer _ = uhd_string_vector_free(&strings);

            var range_start: f64 = 0;
            var range_stop: f64 = 0;

            // Number of channels
            var num_channels: usize = 0;
            ret = uhd_usrp_get_rx_num_channels(self.usrp, &num_channels);
            if (ret != 0) {
                printLastError("uhd_usrp_get_rx_num_channels()");
                return UHDError.InitializationError;
            }
            std.debug.print("[UHDSource] Number of RX channels: {d}\n", .{num_channels});

            for (0..num_channels) |channel| {
                std.debug.print("[UHDSource] RX Channel {d}\n", .{channel});

                // Supported sample rates
                ret = uhd_usrp_get_rx_rates(self.usrp, channel, range);
                if (ret != 0) {
                    printLastError("uhd_usrp_get_rx_rates()");
                    return UHDError.InitializationError;
                }
                _ = uhd_meta_range_start(range, &range_start);
                _ = uhd_meta_range_stop(range, &range_stop);
                std.debug.print("[UHDSource]     Sample rate:      {d} - {d} Hz\n", .{ range_start, range_stop });

                // Center frequency range
                ret = uhd_usrp_get_rx_freq_range(self.usrp, channel, range);
                if (ret != 0) {
                    printLastError("uhd_usrp_get_rx_freq_range()");
                    return UHDError.InitializationError;
                }
                _ = uhd_meta_range_start(range, &range_start);
                _ = uhd_meta_range_stop(range, &range_stop);
                std.debug.print("[UHDSource]     Center frequency: {d} - {d} Hz\n", .{ range_start, range_stop });

                // Bandwidth range
                ret = uhd_usrp_get_rx_bandwidth_range(self.usrp, channel, range);
                if (ret != 0) {
                    printLastError("uhd_usrp_get_rx_bandwidth_range()");
                    return UHDError.InitializationError;
                }
                _ = uhd_meta_range_start(range, &range_start);
                _ = uhd_meta_range_stop(range, &range_stop);
                std.debug.print("[UHDSource]     Bandwidth:        {d} - {d} Hz\n", .{ range_start, range_stop });

                // Overall gain range
                ret = uhd_usrp_get_rx_gain_range(self.usrp, "", channel, range);
                if (ret != 0) {
                    printLastError("uhd_usrp_get_rx_gain_range()");
                    return UHDError.InitializationError;
                }
                _ = uhd_meta_range_start(range, &range_start);
                _ = uhd_meta_range_stop(range, &range_stop);
                std.debug.print("[UHDSource]     Overall gain:     {d} - {d} dB\n", .{ range_start, range_stop });

                // Gain element ranges
                std.debug.print("[UHDSource]     Gain elements:\n", .{});
                ret = uhd_usrp_get_rx_gain_names(self.usrp, channel, &strings);
                if (ret != 0) {
                    printLastError("uhd_usrp_get_rx_gain_names()");
                    return UHDError.InitializationError;
                }
                var num_strings: usize = 0;
                _ = uhd_string_vector_size(strings, &num_strings);
                for (0..num_strings) |i| {
                    var gain_name: [128:0]u8 = @splat(0);
                    _ = uhd_string_vector_at(strings, i, &gain_name, gain_name.len);

                    ret = uhd_usrp_get_rx_gain_range(self.usrp, &gain_name, channel, range);
                    if (ret != 0) {
                        printLastError("uhd_usrp_get_rx_gain_range()");
                        return UHDError.InitializationError;
                    }
                    _ = uhd_meta_range_start(range, &range_start);
                    _ = uhd_meta_range_stop(range, &range_stop);
                    std.debug.print("[UHDSource]         {s: <8}      {d} - {d} dB\n", .{ std.mem.sliceTo(&gain_name, 0), range_start, range_stop });
                }

                // Antennas
                std.debug.print("[UHDSource]     Antennas:\n", .{});
                ret = uhd_usrp_get_rx_antennas(self.usrp, channel, &strings);
                if (ret != 0) {
                    printLastError("uhd_usrp_get_rx_antennas()");
                    return UHDError.InitializationError;
                }
                _ = uhd_string_vector_size(strings, &num_strings);
                for (0..num_strings) |i| {
                    var antenna: [128:0]u8 = @splat(0);
                    _ = uhd_string_vector_at(strings, i, &antenna, antenna.len);
                    std.debug.print("[UHDSource]         {s}\n", .{std.mem.sliceTo(&antenna, 0)});
                }
            }
        }

        // Set antenna, if specified
        if (self.options.antenna) |antenna| {
            ret = uhd_usrp_set_rx_antenna(self.usrp, antenna, self.options.channel);
            if (ret != 0) {
                printLastError("uhd_usrp_set_rx_antenna()");
                return UHDError.InitializationError;
            }
        }

        // Set sample rate
        ret = uhd_usrp_set_rx_rate(self.usrp, self.rate, self.options.channel);
        if (ret != 0) {
            printLastError("uhd_usrp_set_rx_rate()");
            return UHDError.InitializationError;
        }

        // Check configured sample rate
        var actual_rate: f64 = 0;
        ret = uhd_usrp_get_rx_rate(self.usrp, self.options.channel, &actual_rate);
        if (ret != 0) {
            printLastError("uhd_usrp_get_rx_rate()");
            return UHDError.InitializationError;
        }
        if (@abs(actual_rate - self.rate) > 1.0) {
            std.debug.print("[UHDSource] Warning: requested sample rate {d} Hz, configured sample rate {d} Hz\n", .{ self.rate, actual_rate });
        }

        // Set bandwidth, if specified
        if (self.options.bandwidth) |bandwidth| {
            ret = uhd_usrp_set_rx_bandwidth(self.usrp, bandwidth, self.options.channel);
            if (ret != 0) {
                printLastError("uhd_usrp_set_rx_bandwidth()");
                return UHDError.InitializationError;
            }
        }

        if (self.options.gain) |gain| {
            // Set overall gain
            ret = uhd_usrp_set_rx_gain(self.usrp, gain, self.options.channel, "");
            if (ret != 0) {
                printLastError("uhd_usrp_set_rx_gain()");
                return UHDError.InitializationError;
            }
        } else if (self.options.gains == null) {
            // Enable AGC
            ret = uhd_usrp_set_rx_agc(self.usrp, true, self.options.channel);
            if (ret != 0) {
                printLastError("uhd_usrp_set_rx_agc()");
                return UHDError.InitializationError;
            }
        }

        // Set gain elements, if specified
        if (self.options.gains) |gains| {
            for (gains) |gain| {
                ret = uhd_usrp_set_rx_gain(self.usrp, gain.value, self.options.channel, gain.name);
                if (ret != 0) {
                    printLastError("uhd_usrp_set_rx_gain()");
                    return UHDError.InitializationError;
                }
            }
        }

        // Set frequency
        try self.setFrequency(self.frequency);

        if (self.options.debug) {
            var actual_frequency: f64 = 0;
            var actual_bandwidth: f64 = 0;
            var actual_gain: f64 = 0;
            _ = uhd_usrp_get_rx_freq(self.usrp, self.options.channel, &actual_frequency);
            _ = uhd_usrp_get_rx_bandwidth(self.usrp, self.options.channel, &actual_bandwidth);
            _ = uhd_usrp_get_rx_gain(self.usrp, self.options.channel, "", &actual_gain);

            std.debug.print("[UHDSource] Frequency: {d} Hz, Sample rate: {d} Hz\n", .{ self.frequency, self.rate });
            std.debug.print("[UHDSource] Configured Frequency: {d} Hz, Configured Sample Rate: {d} Hz\n", .{ actual_frequency, actual_rate });
            if (self.options.gain != null or self.options.gains != null) {
                std.debug.print("[UHDSource] Configured Bandwidth: {d} Hz, Configured Gain: {d} dB\n", .{ actual_bandwidth, actual_gain });
            } else {
                std.debug.print("[UHDSource] Configured Bandwidth: {d} Hz, Configured Gain: auto\n", .{actual_bandwidth});
            }
        }

        // Set up RX streamer for complex float samples
        var channel_list = [1]usize{self.options.channel};
        var stream_args = uhd_stream_args_t{
            .cpu_format = @constCast("fc32"),
            .otw_format = @constCast("sc16"),
            .args = @constCast(""),
            .channel_list = &channel_list,
            .n_channels = 1,
        };
        ret = uhd_usrp_get_rx_stream(self.usrp, &stream_args, self.rx_streamer);
        if (ret != 0) {
            printLastError("uhd_usrp_get_rx_stream()");
            return UHDError.InitializationError;
        }

        // Get maximum number of samples per read
        ret = uhd_rx_streamer_max_num_samps(self.rx_streamer, &self.chunk_size);
        if (ret != 0) {
            printLastError("uhd_rx_streamer_max_num_samps()");
            return UHDError.InitializationError;
        }
    }

    pub fn deinitialize(self: *UHDSource, _: std.mem.Allocator, _: std.Io) void {
        // Stop streaming
        if (self.streaming) {
            const stream_cmd = uhd_stream_cmd_t{
                .stream_mode = UHD_STREAM_MODE_STOP_CONTINUOUS,
                .num_samps = 0,
                .stream_now = true,
                .time_spec_full_secs = 0,
                .time_spec_frac_secs = 0,
            };
            _ = uhd_rx_streamer_issue_stream_cmd(self.rx_streamer, &stream_cmd);
        }

        // Free RX metadata and RX streamer
        if (self.rx_metadata != null) _ = uhd_rx_metadata_free(&self.rx_metadata);
        if (self.rx_streamer != null) _ = uhd_rx_streamer_free(&self.rx_streamer);

        // Close our device
        if (self.usrp != null) _ = uhd_usrp_free(&self.usrp);
    }

    pub fn process(self: *UHDSource, z: []std.math.Complex(f32)) !ProcessResult {
        // Compute read length
        const len = @min(self.chunk_size, z.len);

        // Check read length is non-zero (i.e. there is sufficient space in output buffer)
        if (len == 0) {
            return ProcessResult.init(&[0]usize{}, &[1]usize{0});
        }

        // Start streaming on first read
        if (!self.streaming) {
            const stream_cmd = uhd_stream_cmd_t{
                .stream_mode = UHD_STREAM_MODE_START_CONTINUOUS,
                .num_samps = 0,
                .stream_now = true,
                .time_spec_full_secs = 0,
                .time_spec_frac_secs = 0,
            };
            const ret = uhd_rx_streamer_issue_stream_cmd(self.rx_streamer, &stream_cmd);
            if (ret != 0) {
                printLastError("uhd_rx_streamer_issue_stream_cmd()");
                return UHDError.ReadError;
            }
            self.streaming = true;
        }

        // Read samples directly into output buffer
        var buffs = [1]?*anyopaque{z.ptr};
        var num_samples: usize = 0;
        const ret = uhd_rx_streamer_recv(self.rx_streamer, &buffs, len, &self.rx_metadata, RECV_TIMEOUT, false, &num_samples);
        if (ret != 0) {
            printLastError("uhd_rx_streamer_recv()");
            return UHDError.ReadError;
        }

        // Check error code in metadata (overflows are reported by libuhd and tolerated)
        var error_code: uhd_rx_metadata_error_code_t = UHD_RX_METADATA_ERROR_CODE_NONE;
        _ = uhd_rx_metadata_error_code(self.rx_metadata, &error_code);
        if (error_code != UHD_RX_METADATA_ERROR_CODE_NONE and error_code != UHD_RX_METADATA_ERROR_CODE_OVERFLOW) {
            std.debug.print("uhd_rx_streamer_recv(): metadata error code {d}\n", .{error_code});
            return UHDError.ReadError;
        }

        return ProcessResult.init(&[0]usize{}, &[1]usize{num_samples});
    }

    pub fn setFrequency(self: *UHDSource, frequency: f64) !void {
        // Set frequency
        var tune_request = uhd_tune_request_t{
            .target_freq = frequency,
            .rf_freq_policy = UHD_TUNE_REQUEST_POLICY_AUTO,
            .rf_freq = 0,
            .dsp_freq_policy = UHD_TUNE_REQUEST_POLICY_AUTO,
            .dsp_freq = 0,
            .args = @constCast(""),
        };
        var tune_result: uhd_tune_result_t = undefined;
        const ret = uhd_usrp_set_rx_freq(self.usrp, &tune_request, self.options.channel, &tune_result);
        if (ret != 0) {
            printLastError("uhd_usrp_set_rx_freq()");
            return UHDError.InitializationError;
        }

        self.frequency = frequency;
    }

    fn printLastError(function: []const u8) void {
        var message: [512:0]u8 = @splat(0);
        _ = uhd_get_last_error(&message, message.len);
        std.debug.print("{s}: {s}\n", .{ function, std.mem.sliceTo(&message, 0) });
    }
};
