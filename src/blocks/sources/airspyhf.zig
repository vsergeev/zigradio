// @block AirspyHFSource
// @description Source a complex-valued signal from an Airspy HF+. This source
// requires the libairspyhf library.
// @category Sources
// @param frequency f64 Tuning frequency in Hz
// @param rate f64 Sample rate in Hz (e.g. 192 kHz, 256 kHz, 384 kHz, 768 kHz)
// @param options Options Additional options:
//      * `hf_agc` (`bool`, default true)
//      * `hf_agc_threshold` (`enum { Low, High}`, default .Low)
//      * `hf_att` (`u8`, default 0 dB, for manual attenuation when HF AGC is
//                  disabled, range of 0 to 48 dB, 6 dB step)
//      * `hf_lna` (`bool`, default false)
//      * `device_serial` (`?u64`, default null)
//      * `debug` (`bool`, default false)
// @signature > out1:Complex(f32)
// @usage
// var src = radio.blocks.AirspyHFSource.init(7.150e6, 192e3, .{ .hf_lna = true });
// try top.connect(&src.block, &snk.block);

const std = @import("std");
const builtin = @import("builtin");

const Block = @import("../../radio.zig").Block;
const SampleMux = @import("../../core/sample_mux.zig").SampleMux;

////////////////////////////////////////////////////////////////////////////////
// libairspyhf API
////////////////////////////////////////////////////////////////////////////////

const struct_airspyhf_device = opaque {};
const airspyhf_device_t = struct_airspyhf_device;

const airspyhf_lib_version_t = extern struct {
    major_version: u32,
    minor_version: u32,
    revision: u32,
};

const airspyhf_read_partid_serialno_t = extern struct {
    part_id: u32,
    serial_no: [4]u32,
};

const airspyhf_user_output_t = c_uint;

const airspyhf_user_output_state_t = c_uint;

const airspyhf_complex_float_t = extern struct {
    re: f32,
    im: f32,
};

const airspyhf_transfer_t = extern struct {
    device: ?*airspyhf_device_t,
    ctx: ?*anyopaque,
    samples: [*c]airspyhf_complex_float_t,
    sample_count: c_int,
    dropped_samples: u64,
};

const airspyhf_sample_block_cb_fn = ?*const fn (*airspyhf_transfer_t) callconv(.c) c_int;

var airspyhf_lib_version: *const fn (lib_version: [*c]airspyhf_lib_version_t) callconv(.c) void = undefined;
var airspyhf_list_devices: *const fn (serials: [*c]u64, count: c_int) callconv(.c) c_int = undefined;
var airspyhf_open: *const fn (device: [*c]?*airspyhf_device_t) callconv(.c) c_int = undefined;
var airspyhf_open_sn: *const fn (device: [*c]?*airspyhf_device_t, serial_number: u64) callconv(.c) c_int = undefined;
var airspyhf_open_fd: *const fn (device: [*c]?*airspyhf_device_t, fd: c_int) callconv(.c) c_int = undefined;
var airspyhf_close: *const fn (device: ?*airspyhf_device_t) callconv(.c) c_int = undefined;
var airspyhf_get_output_size: *const fn (device: ?*airspyhf_device_t) callconv(.c) c_int = undefined;
var airspyhf_start: *const fn (device: ?*airspyhf_device_t, callback: airspyhf_sample_block_cb_fn, ctx: ?*anyopaque) callconv(.c) c_int = undefined;
var airspyhf_stop: *const fn (device: ?*airspyhf_device_t) callconv(.c) c_int = undefined;
var airspyhf_is_streaming: *const fn (device: ?*airspyhf_device_t) callconv(.c) c_int = undefined;
var airspyhf_is_low_if: *const fn (device: ?*airspyhf_device_t) callconv(.c) c_int = undefined;
var airspyhf_set_freq: *const fn (device: ?*airspyhf_device_t, freq_hz: u32) callconv(.c) c_int = undefined;
var airspyhf_set_freq_double: *const fn (device: ?*airspyhf_device_t, freq_hz: f64) callconv(.c) c_int = undefined;
var airspyhf_set_lib_dsp: *const fn (device: ?*airspyhf_device_t, flag: u8) callconv(.c) c_int = undefined;
var airspyhf_get_samplerates: *const fn (device: ?*airspyhf_device_t, buffer: [*c]u32, len: u32) callconv(.c) c_int = undefined;
var airspyhf_set_samplerate: *const fn (device: ?*airspyhf_device_t, samplerate: u32) callconv(.c) c_int = undefined;
var airspyhf_set_att: *const fn (device: ?*airspyhf_device_t, value: f32) callconv(.c) c_int = undefined;
var airspyhf_get_att_steps: *const fn (device: ?*airspyhf_device_t, buffer: ?*anyopaque, len: u32) callconv(.c) c_int = undefined;
var airspyhf_set_bias_tee: *const fn (device: ?*airspyhf_device_t, value: i8) callconv(.c) c_int = undefined;
var airspyhf_get_bias_tee_count: *const fn (device: ?*airspyhf_device_t, count: [*c]i32) callconv(.c) c_int = undefined;
var airspyhf_get_bias_tee_name: *const fn (device: ?*airspyhf_device_t, index: i32, version: [*c]u8, length: u8) callconv(.c) c_int = undefined;
var airspyhf_get_calibration: *const fn (device: ?*airspyhf_device_t, ppb: [*c]i32) callconv(.c) c_int = undefined;
var airspyhf_set_calibration: *const fn (device: ?*airspyhf_device_t, ppb: i32) callconv(.c) c_int = undefined;
var airspyhf_get_vctcxo_calibration: *const fn (device: ?*airspyhf_device_t, vc: [*c]u16) callconv(.c) c_int = undefined;
var airspyhf_set_vctcxo_calibration: *const fn (device: ?*airspyhf_device_t, vc: u16) callconv(.c) c_int = undefined;
var airspyhf_get_frontend_options: *const fn (device: ?*airspyhf_device_t, flags: [*c]u32) callconv(.c) c_int = undefined;
var airspyhf_set_frontend_options: *const fn (device: ?*airspyhf_device_t, flags: u32) callconv(.c) c_int = undefined;
var airspyhf_set_optimal_iq_correction_point: *const fn (device: ?*airspyhf_device_t, w: f32) callconv(.c) c_int = undefined;
var airspyhf_iq_balancer_configure: *const fn (device: ?*airspyhf_device_t, buffers_to_skip: c_int, fft_integration: c_int, fft_overlap: c_int, correlation_integration: c_int) callconv(.c) c_int = undefined;
var airspyhf_flash_configuration: *const fn (device: ?*airspyhf_device_t) callconv(.c) c_int = undefined;
var airspyhf_board_partid_serialno_read: *const fn (device: ?*airspyhf_device_t, read_partid_serialno: [*c]airspyhf_read_partid_serialno_t) callconv(.c) c_int = undefined;
var airspyhf_version_string_read: *const fn (device: ?*airspyhf_device_t, version: [*c]u8, length: u8) callconv(.c) c_int = undefined;
var airspyhf_set_user_output: *const fn (device: ?*airspyhf_device_t, pin: airspyhf_user_output_t, value: airspyhf_user_output_state_t) callconv(.c) c_int = undefined;
var airspyhf_set_hf_agc: *const fn (device: ?*airspyhf_device_t, flag: u8) callconv(.c) c_int = undefined;
var airspyhf_set_hf_agc_threshold: *const fn (device: ?*airspyhf_device_t, flag: u8) callconv(.c) c_int = undefined;
var airspyhf_set_hf_att: *const fn (device: ?*airspyhf_device_t, att_index: u8) callconv(.c) c_int = undefined;
var airspyhf_set_hf_lna: *const fn (device: ?*airspyhf_device_t, flag: u8) callconv(.c) c_int = undefined;
var airspyhf_loaded: bool = false;

////////////////////////////////////////////////////////////////////////////////
// AirspyHF Source
////////////////////////////////////////////////////////////////////////////////

pub const AirspyHFSource = struct {
    // Options
    pub const Options = struct {
        hf_agc: bool = true,
        hf_agc_threshold: enum { Low, High } = .Low,
        hf_att: u8 = 0,
        hf_lna: bool = false,
        device_serial: ?u64 = null,
        debug: bool = false,
    };

    // Errors
    pub const AirspyHFError = error{
        InitializationError,
        UnsupportedError,
    };

    block: Block,

    // Configuration
    frequency: f64,
    rate: f64,
    options: Options,

    // State
    dev: ?*airspyhf_device_t = null,
    sample_mux: SampleMux = undefined,

    pub fn init(frequency: f64, rate: f64, options: Options) AirspyHFSource {
        return .{ .block = Block.initRaw(@This(), &[0]type{}, &[1]type{std.math.Complex(f32)}), .frequency = frequency, .rate = rate, .options = options };
    }

    pub fn setRate(self: *AirspyHFSource, _: f64) !f64 {
        return self.rate;
    }

    pub fn initialize(self: *AirspyHFSource, _: std.mem.Allocator) !void {
        // Open libairspyhf library
        if (!airspyhf_loaded) {
            var lib = try std.DynLib.open("libairspyhf.so");
            airspyhf_lib_version = lib.lookup(@TypeOf(airspyhf_lib_version), "airspyhf_lib_version") orelse return error.LookupFail;
            airspyhf_list_devices = lib.lookup(@TypeOf(airspyhf_list_devices), "airspyhf_list_devices") orelse return error.LookupFail;
            airspyhf_open = lib.lookup(@TypeOf(airspyhf_open), "airspyhf_open") orelse return error.LookupFail;
            airspyhf_open_sn = lib.lookup(@TypeOf(airspyhf_open_sn), "airspyhf_open_sn") orelse return error.LookupFail;
            airspyhf_open_fd = lib.lookup(@TypeOf(airspyhf_open_fd), "airspyhf_open_fd") orelse return error.LookupFail;
            airspyhf_close = lib.lookup(@TypeOf(airspyhf_close), "airspyhf_close") orelse return error.LookupFail;
            airspyhf_get_output_size = lib.lookup(@TypeOf(airspyhf_get_output_size), "airspyhf_get_output_size") orelse return error.LookupFail;
            airspyhf_start = lib.lookup(@TypeOf(airspyhf_start), "airspyhf_start") orelse return error.LookupFail;
            airspyhf_stop = lib.lookup(@TypeOf(airspyhf_stop), "airspyhf_stop") orelse return error.LookupFail;
            airspyhf_is_streaming = lib.lookup(@TypeOf(airspyhf_is_streaming), "airspyhf_is_streaming") orelse return error.LookupFail;
            airspyhf_is_low_if = lib.lookup(@TypeOf(airspyhf_is_low_if), "airspyhf_is_low_if") orelse return error.LookupFail;
            airspyhf_set_freq = lib.lookup(@TypeOf(airspyhf_set_freq), "airspyhf_set_freq") orelse return error.LookupFail;
            airspyhf_set_freq_double = lib.lookup(@TypeOf(airspyhf_set_freq_double), "airspyhf_set_freq_double") orelse return error.LookupFail;
            airspyhf_set_lib_dsp = lib.lookup(@TypeOf(airspyhf_set_lib_dsp), "airspyhf_set_lib_dsp") orelse return error.LookupFail;
            airspyhf_get_samplerates = lib.lookup(@TypeOf(airspyhf_get_samplerates), "airspyhf_get_samplerates") orelse return error.LookupFail;
            airspyhf_set_samplerate = lib.lookup(@TypeOf(airspyhf_set_samplerate), "airspyhf_set_samplerate") orelse return error.LookupFail;
            airspyhf_set_att = lib.lookup(@TypeOf(airspyhf_set_att), "airspyhf_set_att") orelse return error.LookupFail;
            airspyhf_get_att_steps = lib.lookup(@TypeOf(airspyhf_get_att_steps), "airspyhf_get_att_steps") orelse return error.LookupFail;
            airspyhf_set_bias_tee = lib.lookup(@TypeOf(airspyhf_set_bias_tee), "airspyhf_set_bias_tee") orelse return error.LookupFail;
            airspyhf_get_bias_tee_count = lib.lookup(@TypeOf(airspyhf_get_bias_tee_count), "airspyhf_get_bias_tee_count") orelse return error.LookupFail;
            airspyhf_get_bias_tee_name = lib.lookup(@TypeOf(airspyhf_get_bias_tee_name), "airspyhf_get_bias_tee_name") orelse return error.LookupFail;
            airspyhf_get_calibration = lib.lookup(@TypeOf(airspyhf_get_calibration), "airspyhf_get_calibration") orelse return error.LookupFail;
            airspyhf_set_calibration = lib.lookup(@TypeOf(airspyhf_set_calibration), "airspyhf_set_calibration") orelse return error.LookupFail;
            airspyhf_get_vctcxo_calibration = lib.lookup(@TypeOf(airspyhf_get_vctcxo_calibration), "airspyhf_get_vctcxo_calibration") orelse return error.LookupFail;
            airspyhf_set_vctcxo_calibration = lib.lookup(@TypeOf(airspyhf_set_vctcxo_calibration), "airspyhf_set_vctcxo_calibration") orelse return error.LookupFail;
            airspyhf_get_frontend_options = lib.lookup(@TypeOf(airspyhf_get_frontend_options), "airspyhf_get_frontend_options") orelse return error.LookupFail;
            airspyhf_set_frontend_options = lib.lookup(@TypeOf(airspyhf_set_frontend_options), "airspyhf_set_frontend_options") orelse return error.LookupFail;
            airspyhf_set_optimal_iq_correction_point = lib.lookup(@TypeOf(airspyhf_set_optimal_iq_correction_point), "airspyhf_set_optimal_iq_correction_point") orelse return error.LookupFail;
            airspyhf_iq_balancer_configure = lib.lookup(@TypeOf(airspyhf_iq_balancer_configure), "airspyhf_iq_balancer_configure") orelse return error.LookupFail;
            airspyhf_flash_configuration = lib.lookup(@TypeOf(airspyhf_flash_configuration), "airspyhf_flash_configuration") orelse return error.LookupFail;
            airspyhf_board_partid_serialno_read = lib.lookup(@TypeOf(airspyhf_board_partid_serialno_read), "airspyhf_board_partid_serialno_read") orelse return error.LookupFail;
            airspyhf_version_string_read = lib.lookup(@TypeOf(airspyhf_version_string_read), "airspyhf_version_string_read") orelse return error.LookupFail;
            airspyhf_set_user_output = lib.lookup(@TypeOf(airspyhf_set_user_output), "airspyhf_set_user_output") orelse return error.LookupFail;
            airspyhf_set_hf_agc = lib.lookup(@TypeOf(airspyhf_set_hf_agc), "airspyhf_set_hf_agc") orelse return error.LookupFail;
            airspyhf_set_hf_agc_threshold = lib.lookup(@TypeOf(airspyhf_set_hf_agc_threshold), "airspyhf_set_hf_agc_threshold") orelse return error.LookupFail;
            airspyhf_set_hf_att = lib.lookup(@TypeOf(airspyhf_set_hf_att), "airspyhf_set_hf_att") orelse return error.LookupFail;
            airspyhf_set_hf_lna = lib.lookup(@TypeOf(airspyhf_set_hf_lna), "airspyhf_set_hf_lna") orelse return error.LookupFail;
            airspyhf_loaded = true;
        }

        self.dev = null;

        // Open device
        var ret = if (self.options.device_serial) |serial| airspyhf_open_sn(&self.dev, serial) else airspyhf_open(&self.dev);
        if (ret != 0) {
            std.debug.print("airspyhf_open(): {d}\n", .{ret});
            return AirspyHFError.InitializationError;
        }

        // Dump version info
        if (self.options.debug) {
            // Look up library version
            var lib_version: airspyhf_lib_version_t = undefined;
            airspyhf_lib_version(&lib_version);

            // Look up firmware version
            var firmware_version: [64:0]u8 = undefined;
            ret = airspyhf_version_string_read(self.dev, &firmware_version, firmware_version.len);
            if (ret != 0) {
                std.debug.print("airspyhf_version_string_read(): {d}\n", .{ret});
                return AirspyHFError.InitializationError;
            }

            // Look up board info
            var board_info: airspyhf_read_partid_serialno_t = undefined;
            ret = airspyhf_board_partid_serialno_read(self.dev, &board_info);
            if (ret != 0) {
                std.debug.print("airspyhf_board_partid_serialno_read(): {d}\n", .{ret});
                return AirspyHFError.InitializationError;
            }

            std.debug.print("[AirspyHFSource] Library version:   {d}.{d}.{d}\n", .{ lib_version.major_version, lib_version.minor_version, lib_version.revision });
            std.debug.print("[AirspyHFSource] Firmware version:  {s}\n", .{firmware_version});
            std.debug.print("[AirspyHFSource] Part ID:           0x{x:0>8}\n", .{board_info.part_id});
            std.debug.print("[AirspyHFSource] Serial Number:     0x{x:0>8}{x:0>8}\n", .{ board_info.serial_no[0], board_info.serial_no[1] });
        }

        // Set sample rate
        ret = airspyhf_set_samplerate(self.dev, @intFromFloat(self.rate));
        if (ret != 0) {
            std.debug.print("airspyhf_set_samplerate(): {d}\n", .{ret});
            return AirspyHFError.InitializationError;
        }

        std.debug.print("[AirspyHFSource] Frequency: {d} Hz, Sample rate: {d} Hz\n", .{ self.frequency, self.rate });

        // Set HF AGC
        ret = airspyhf_set_hf_agc(self.dev, @intFromBool(self.options.hf_agc));
        if (ret != 0) {
            std.debug.print("airspyhf_set_hf_agc(): {d}\n", .{ret});
            return AirspyHFError.InitializationError;
        }

        if (self.options.hf_agc) {
            // Set HF AGC Threshold
            ret = airspyhf_set_hf_agc_threshold(self.dev, if (self.options.hf_agc_threshold == .High) 1 else 0);
            if (ret != 0) {
                std.debug.print("airspyhf_set_hf_agc_threshold(): {d}\n", .{ret});
                return AirspyHFError.InitializationError;
            }
        } else {
            // Set HF Attenuator
            ret = airspyhf_set_hf_att(self.dev, self.options.hf_att);
            if (ret != 0) {
                std.debug.print("airspyhf_set_hf_att(): {d}\n", .{ret});
                return AirspyHFError.InitializationError;
            }
        }

        // Set HF LNA
        ret = airspyhf_set_hf_lna(self.dev, @intFromBool(self.options.hf_lna));
        if (ret != 0) {
            std.debug.print("airspyhf_set_hf_lna(): {d}\n", .{ret});
            return AirspyHFError.InitializationError;
        }

        // Set frequency
        ret = airspyhf_set_freq(self.dev, @intFromFloat(self.frequency));
        if (ret != 0) {
            std.debug.print("airspyhf_set_freq(): {d}\n", .{ret});
            return AirspyHFError.InitializationError;
        }
    }

    pub fn deinitialize(self: *AirspyHFSource, _: std.mem.Allocator) void {
        // Close device
        if (self.dev != null) {
            const ret = airspyhf_close(self.dev);
            if (ret != 0) {
                std.debug.print("airspyhf_close(): {d}\n", .{ret});
            }
        }
    }

    fn callback(transfer: *airspyhf_transfer_t) callconv(.c) c_int {
        var self: *AirspyHFSource = @ptrCast(@alignCast(transfer.ctx));

        // Check for dropped samples
        if (transfer.dropped_samples != 0) {
            std.debug.print("[AirspyHFSource] Warning: {d} samples dropped\n", .{transfer.dropped_samples});
        }

        const samples_count: usize = @intCast(transfer.sample_count);
        const samples_byte_count = samples_count * @sizeOf(std.math.Complex(f32));

        // Get sample mux output buffer
        var buffer = self.sample_mux.vtable.getOutputBuffer(self.sample_mux.ptr, 0);

        // If output buffer has insufficient space
        if (buffer.len < samples_byte_count) {
            self.sample_mux.vtable.waitOutputAvailable(self.sample_mux.ptr, 0, samples_byte_count, null) catch |err| switch (err) {
                error.Timeout => unreachable,
                error.BrokenStream => return -1,
            };

            buffer = self.sample_mux.vtable.getOutputBuffer(self.sample_mux.ptr, 0);
        }

        // Copy to sample mux output buffer
        var samples_buffer: []std.math.Complex(f32) = @alignCast(std.mem.bytesAsSlice(std.math.Complex(f32), buffer[0..std.mem.alignBackward(usize, buffer.len, @sizeOf(std.math.Complex(f32)))]));
        @memcpy(samples_buffer[0..samples_count], @as([*]std.math.Complex(f32), @ptrCast(transfer.samples))[0..samples_count]);

        // Update sample mux output buffer
        self.sample_mux.vtable.updateOutputBuffer(self.sample_mux.ptr, 0, samples_byte_count);

        return 0;
    }

    pub fn start(self: *AirspyHFSource, sample_mux: SampleMux) !void {
        self.sample_mux = sample_mux;

        // Start stream
        const ret = airspyhf_start(self.dev, callback, self);
        if (ret != 0) {
            std.debug.print("airspyhf_start(): {d}\n", .{ret});
            return AirspyHFError.InitializationError;
        }
    }

    pub fn stop(self: *AirspyHFSource) void {
        // Stop stream
        const ret = airspyhf_stop(self.dev);
        if (ret != 0) {
            std.debug.print("airspyhf_stop(): {d}\n", .{ret});
        }

        self.sample_mux.setEOS();
    }

    pub fn setFrequency(self: *AirspyHFSource, frequency: f64) !void {
        // Set frequency
        const ret = airspyhf_set_freq(self.dev, @intFromFloat(frequency));
        if (ret != 0) {
            std.debug.print("airspyhf_set_freq(): {d}\n", .{ret});
            return AirspyHFError.InitializationError;
        }

        self.frequency = frequency;
    }
};
