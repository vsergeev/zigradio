const std = @import("std");
const builtin = @import("builtin");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// librtlsdr API
////////////////////////////////////////////////////////////////////////////////

const struct_rtlsdr_dev = opaque {};
const rtlsdr_dev_t = struct_rtlsdr_dev;

var rtlsdr_open: *const fn (dev: [*c]?*rtlsdr_dev_t, index: u32) c_int = undefined;
var rtlsdr_get_device_name: *const fn (index: u32) [*c]const u8 = undefined;
var rtlsdr_get_usb_strings: *const fn (dev: ?*rtlsdr_dev_t, manufact: [*c]u8, product: [*c]u8, serial: [*c]u8) c_int = undefined;
var rtlsdr_set_bias_tee: *const fn (dev: ?*rtlsdr_dev_t, on: c_int) c_int = undefined;
var rtlsdr_set_direct_sampling: *const fn (dev: ?*rtlsdr_dev_t, on: c_int) c_int = undefined;
var rtlsdr_set_tuner_gain_mode: *const fn (dev: ?*rtlsdr_dev_t, manual: c_int) c_int = undefined;
var rtlsdr_set_agc_mode: *const fn (dev: ?*rtlsdr_dev_t, on: c_int) c_int = undefined;
var rtlsdr_set_tuner_gain: *const fn (dev: ?*rtlsdr_dev_t, gain: c_int) c_int = undefined;
var rtlsdr_set_freq_correction: *const fn (dev: ?*rtlsdr_dev_t, ppm: c_int) c_int = undefined;
var rtlsdr_set_center_freq: *const fn (dev: ?*rtlsdr_dev_t, freq: u32) c_int = undefined;
var rtlsdr_get_center_freq: *const fn (dev: ?*rtlsdr_dev_t) u32 = undefined;
var rtlsdr_set_sample_rate: *const fn (dev: ?*rtlsdr_dev_t, rate: u32) c_int = undefined;
var rtlsdr_get_sample_rate: *const fn (dev: ?*rtlsdr_dev_t) u32 = undefined;
var rtlsdr_set_tuner_bandwidth: *const fn (dev: ?*rtlsdr_dev_t, bw: u32) c_int = undefined;
var rtlsdr_reset_buffer: *const fn (dev: ?*rtlsdr_dev_t) c_int = undefined;
var rtlsdr_read_sync: *const fn (dev: ?*rtlsdr_dev_t, buf: ?*anyopaque, len: c_int, n_read: [*c]c_int) c_int = undefined;
var rtlsdr_close: *const fn (dev: ?*rtlsdr_dev_t) c_int = undefined;
var rtlsdr_loaded: bool = false;

////////////////////////////////////////////////////////////////////////////////
// RTL-SDR Source
////////////////////////////////////////////////////////////////////////////////

pub const RtlSdrSource = struct {
    // Direct Sampling Mode Enum
    pub const DirectSamplingMode = enum { I, Q };

    // Options
    pub const Options = struct {
        biastee: bool = false,
        direct_sampling: ?DirectSamplingMode = null,
        bandwidth: ?f32 = null,
        rf_gain: ?f32 = null,
        freq_correction: isize = 0,
        device_index: usize = 0,
        debug: bool = false,
    };

    // Errors
    pub const RtlSdrError = error{
        InitializationError,
        ReadError,
    };

    // Constants
    const MIN_BLOCK_SIZE = 8192;

    block: Block,

    // Configuration
    frequency: f64,
    rate: f64,
    options: Options,

    // State
    buf: []u8 = undefined,
    dev: ?*rtlsdr_dev_t = null,

    pub fn init(frequency: f64, rate: f64, options: Options) RtlSdrSource {
        return .{ .block = Block.init(@This()), .frequency = frequency, .rate = rate, .options = options };
    }

    pub fn setRate(self: *RtlSdrSource, _: f64) !f64 {
        return self.rate;
    }

    pub fn initialize(self: *RtlSdrSource, allocator: std.mem.Allocator) !void {
        // Open librtlsdr library
        if (!rtlsdr_loaded) {
            var lib = try std.DynLib.open("librtlsdr.so");
            rtlsdr_open = lib.lookup(@TypeOf(rtlsdr_open), "rtlsdr_open") orelse return error.LookupFail;
            rtlsdr_get_device_name = lib.lookup(@TypeOf(rtlsdr_get_device_name), "rtlsdr_get_device_name") orelse return error.LookupFail;
            rtlsdr_get_usb_strings = lib.lookup(@TypeOf(rtlsdr_get_usb_strings), "rtlsdr_get_usb_strings") orelse return error.LookupFail;
            rtlsdr_set_bias_tee = lib.lookup(@TypeOf(rtlsdr_set_bias_tee), "rtlsdr_set_bias_tee") orelse return error.LookupFail;
            rtlsdr_set_direct_sampling = lib.lookup(@TypeOf(rtlsdr_set_direct_sampling), "rtlsdr_set_direct_sampling") orelse return error.LookupFail;
            rtlsdr_set_tuner_gain_mode = lib.lookup(@TypeOf(rtlsdr_set_tuner_gain_mode), "rtlsdr_set_tuner_gain_mode") orelse return error.LookupFail;
            rtlsdr_set_agc_mode = lib.lookup(@TypeOf(rtlsdr_set_agc_mode), "rtlsdr_set_agc_mode") orelse return error.LookupFail;
            rtlsdr_set_tuner_gain = lib.lookup(@TypeOf(rtlsdr_set_tuner_gain), "rtlsdr_set_tuner_gain") orelse return error.LookupFail;
            rtlsdr_set_freq_correction = lib.lookup(@TypeOf(rtlsdr_set_freq_correction), "rtlsdr_set_freq_correction") orelse return error.LookupFail;
            rtlsdr_set_center_freq = lib.lookup(@TypeOf(rtlsdr_set_center_freq), "rtlsdr_set_center_freq") orelse return error.LookupFail;
            rtlsdr_get_center_freq = lib.lookup(@TypeOf(rtlsdr_get_center_freq), "rtlsdr_get_center_freq") orelse return error.LookupFail;
            rtlsdr_set_sample_rate = lib.lookup(@TypeOf(rtlsdr_set_sample_rate), "rtlsdr_set_sample_rate") orelse return error.LookupFail;
            rtlsdr_get_sample_rate = lib.lookup(@TypeOf(rtlsdr_get_sample_rate), "rtlsdr_get_sample_rate") orelse return error.LookupFail;
            rtlsdr_set_tuner_bandwidth = lib.lookup(@TypeOf(rtlsdr_set_tuner_bandwidth), "rtlsdr_set_tuner_bandwidth") orelse return error.LookupFail;
            rtlsdr_reset_buffer = lib.lookup(@TypeOf(rtlsdr_reset_buffer), "rtlsdr_reset_buffer") orelse return error.LookupFail;
            rtlsdr_read_sync = lib.lookup(@TypeOf(rtlsdr_read_sync), "rtlsdr_read_sync") orelse return error.LookupFail;
            rtlsdr_close = lib.lookup(@TypeOf(rtlsdr_close), "rtlsdr_close") orelse return error.LookupFail;
            rtlsdr_loaded = true;
        }

        // Open device
        var ret = rtlsdr_open(&self.dev, @as(u32, @intCast(self.options.device_index)));
        if (ret != 0) {
            std.debug.print("rtlsdr_open(): {d}\n", .{ret});
            return RtlSdrError.InitializationError;
        }

        // Dump debug info
        if (self.options.debug) {
            // Look up device name
            const device_name = rtlsdr_get_device_name(@as(u32, @intCast(self.options.device_index)));

            // Look up USB device strings
            var usb_manufacturer: [256]u8 = undefined;
            var usb_product: [256]u8 = undefined;
            var usb_serial: [256]u8 = undefined;
            ret = rtlsdr_get_usb_strings(self.dev, &usb_manufacturer, &usb_product, &usb_serial);
            if (ret != 0) {
                std.debug.print("rtlsdr_get_usb_strings(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }

            std.debug.print("[RtlSdrSource] Device name:       {s}\n", .{device_name});
            std.debug.print("[RtlSdrSource] USB Manufacturer:  {s}\n", .{std.mem.span(@as([*:0]u8, @ptrCast(&usb_manufacturer)))});
            std.debug.print("[RtlSdrSource] USB Product:       {s}\n", .{std.mem.span(@as([*:0]u8, @ptrCast(&usb_product)))});
            std.debug.print("[RtlSdrSource] USB Serial:        {s}\n", .{std.mem.span(@as([*:0]u8, @ptrCast(&usb_serial)))});
        }

        // Turn on bias tee if required, ignore if not required
        if (self.options.biastee) {
            ret = rtlsdr_set_bias_tee(self.dev, 1);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_bias_tee(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }
        }

        // Set direct sampling mode, if enabled
        if (self.options.direct_sampling) |direct_sampling| {
            ret = rtlsdr_set_direct_sampling(self.dev, if (direct_sampling == DirectSamplingMode.I) 1 else 2);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_direct_sampling(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }
        }

        // Set autogain if no manual gain was specified
        if (self.options.rf_gain == null) {
            // Set autogain
            ret = rtlsdr_set_tuner_gain_mode(self.dev, 0);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_tuner_gain_mode(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }

            // Enable AGC
            ret = rtlsdr_set_agc_mode(self.dev, 1);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_agc_mode(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }
        } else {
            // Disable autogain
            ret = rtlsdr_set_tuner_gain_mode(self.dev, 1);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_tuner_gain_mode(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }

            // Disable AGC
            ret = rtlsdr_set_agc_mode(self.dev, 0);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_agc_mode(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }

            // Set RF gain
            ret = rtlsdr_set_tuner_gain(self.dev, @as(c_int, @intFromFloat(self.options.rf_gain.? * 10.0)));
            if (ret != 0) {
                std.debug.print("rtlsdr_set_tuner_gain(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }
        }

        if (self.options.debug) {
            std.debug.print("[RtlSdrSource] Frequency: {d} Hz, Sample rate: {d} Hz\n", .{ self.frequency, self.rate });
        }

        // Set frequency correction
        ret = rtlsdr_set_freq_correction(self.dev, @as(c_int, @intCast(self.options.freq_correction)));
        if (ret != 0 and ret != -2) {
            std.debug.print("rtlsdr_set_freq_correction(): {d}\n", .{ret});
            return RtlSdrError.InitializationError;
        }

        // Set frequency
        ret = rtlsdr_set_center_freq(self.dev, @as(u32, @intFromFloat(self.frequency)));
        if (ret != 0) {
            std.debug.print("rtlsdr_set_center_freq(): {d}\n", .{ret});
            return RtlSdrError.InitializationError;
        }

        // Set sample rate
        ret = rtlsdr_set_sample_rate(self.dev, @as(u32, @intFromFloat(self.rate)));
        if (ret != 0) {
            std.debug.print("rtlsdr_set_sample_rate(): {d}\n", .{ret});
            return RtlSdrError.InitializationError;
        }

        // Set bandwidth
        ret = rtlsdr_set_tuner_bandwidth(self.dev, if (self.options.bandwidth) |bandwidth| @as(u32, @intFromFloat(bandwidth)) else 0);
        if (ret != 0) {
            std.debug.print("rtlsdr_set_tuner_bandwidth(): {d}\n", .{ret});
            return RtlSdrError.InitializationError;
        }

        if (self.options.debug) {
            // Get configured frequency
            const frequency = rtlsdr_get_center_freq(self.dev);
            // Get configured sample rate
            const sample_rate = rtlsdr_get_sample_rate(self.dev);

            std.debug.print("[RtlSdrSource] Configured Frequency: {d} Hz, Configured Sample Rate: {d} Hz\n", .{ frequency, sample_rate });
        }

        // Reset endpoint buffer
        ret = rtlsdr_reset_buffer(self.dev);
        if (ret != 0) {
            std.debug.print("rtlsdr_reset_buffer(): {d}\n", .{ret});
            return RtlSdrError.InitializationError;
        }

        // Allocate read buffer
        self.buf = try allocator.alloc(u8, 16 * 2 * MIN_BLOCK_SIZE);
    }

    pub fn deinitialize(self: *RtlSdrSource, allocator: std.mem.Allocator) void {
        // Turn off bias tee if it was enabled
        if (self.options.biastee) {
            // Turn off bias tee
            const ret = rtlsdr_set_bias_tee(self.dev, 0);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_bias_tee(): {d}\n", .{ret});
            }
        }

        // Close our device
        if (self.dev) |dev| _ = rtlsdr_close(dev);

        // Free buffer
        allocator.free(self.buf);
    }

    pub fn process(self: *RtlSdrSource, z: []std.math.Complex(f32)) !ProcessResult {
        // Compute minimum read length
        const len = @min(self.buf.len, z.len & ~@as(usize, MIN_BLOCK_SIZE - 1));

        // Check read length is non-zero (i.e. there is sufficient space in output buffer)
        if (len == 0) {
            return ProcessResult.init(&[0]usize{}, &[1]usize{0});
        }

        // Read samples
        var num_read: c_int = 0;
        const ret = rtlsdr_read_sync(self.dev, self.buf.ptr, @as(c_int, @intCast(len)), &num_read);
        if (ret != 0) {
            std.debug.print("rtlsdr_read_sync(): {d}\n", .{ret});
            return RtlSdrError.ReadError;
        }

        // Convert complex u8 samples to complex float samples
        const num_samples: usize = @divExact(@as(usize, @intCast(num_read)), 2);
        for (0..num_samples) |i| {
            z[i] = std.math.Complex(f32).init((@as(f32, @floatFromInt(self.buf[2 * i])) - 127.5) * (1.0 / 127.5), (@as(f32, @floatFromInt(self.buf[2 * i + 1])) - 127.5) * (1.0 / 127.5));
        }

        return ProcessResult.init(&[0]usize{}, &[1]usize{num_samples});
    }
};
