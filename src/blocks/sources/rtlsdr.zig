const std = @import("std");
const builtin = @import("builtin");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;
const rtlsdr = @cImport({
    @cInclude("rtl-sdr.h");
});

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
    dev: ?*rtlsdr.rtlsdr_dev_t = null,

    pub fn init(frequency: f64, rate: f64, options: Options) RtlSdrSource {
        if (!comptime platform.hasPackage("librtlsdr")) @compileError("Platform is missing librtlsdr library.");
        return .{ .block = Block.init(@This()), .frequency = frequency, .rate = rate, .options = options };
    }

    pub fn setRate(self: *RtlSdrSource, _: f64) !f64 {
        return self.rate;
    }

    pub fn initialize(self: *RtlSdrSource, allocator: std.mem.Allocator) !void {
        // Open device
        var ret = rtlsdr.rtlsdr_open(&self.dev, @intCast(u32, self.options.device_index));
        if (ret != 0) {
            std.debug.print("rtlsdr_open(): {d}\n", .{ret});
            return RtlSdrError.InitializationError;
        }

        // Dump debug info
        if (self.options.debug) {
            // Look up device name
            const device_name = rtlsdr.rtlsdr_get_device_name(@intCast(u32, self.options.device_index));

            // Look up USB device strings
            var usb_manufacturer: [256]u8 = undefined;
            var usb_product: [256]u8 = undefined;
            var usb_serial: [256]u8 = undefined;
            ret = rtlsdr.rtlsdr_get_usb_strings(self.dev, &usb_manufacturer, &usb_product, &usb_serial);
            if (ret != 0) {
                std.debug.print("rtlsdr_get_usb_strings(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }

            std.debug.print("[RtlSdrSource] Device name:       {s}\n", .{device_name});
            std.debug.print("[RtlSdrSource] USB Manufacturer:  {s}\n", .{std.mem.span(@ptrCast([*:0]u8, &usb_manufacturer))});
            std.debug.print("[RtlSdrSource] USB Product:       {s}\n", .{std.mem.span(@ptrCast([*:0]u8, &usb_product))});
            std.debug.print("[RtlSdrSource] USB Serial:        {s}\n", .{std.mem.span(@ptrCast([*:0]u8, &usb_serial))});
        }

        // Turn on bias tee if required, ignore if not required
        if (self.options.biastee) {
            ret = rtlsdr.rtlsdr_set_bias_tee(self.dev, 1);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_bias_tee(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }
        }

        // Set direct sampling mode, if enabled
        if (self.options.direct_sampling) |direct_sampling| {
            ret = rtlsdr.rtlsdr_set_direct_sampling(self.dev, if (direct_sampling == DirectSamplingMode.I) 1 else 2);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_direct_sampling(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }
        }

        // Set autogain if no manual gain was specified
        if (self.options.rf_gain == null) {
            // Set autogain
            ret = rtlsdr.rtlsdr_set_tuner_gain_mode(self.dev, 0);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_tuner_gain_mode(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }

            // Enable AGC
            ret = rtlsdr.rtlsdr_set_agc_mode(self.dev, 1);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_agc_mode(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }
        } else |rf_gain| {
            // Disable autogain
            ret = rtlsdr.rtlsdr_set_tuner_gain_mode(self.dev, 1);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_tuner_gain_mode(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }

            // Disable AGC
            ret = rtlsdr.rtlsdr_set_agc_mode(self.dev, 0);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_agc_mode(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }

            // Set RF gain
            ret = rtlsdr.rtlsdr_set_tuner_gain(self.dev, @floatToInt(c_int, rf_gain * 10.0));
            if (ret != 0) {
                std.debug.print("rtlsdr_set_tuner_gain(): {d}\n", .{ret});
                return RtlSdrError.InitializationError;
            }
        }

        if (self.options.debug) {
            std.debug.print("[RtlSdrSource] Frequency: {d} Hz, Sample rate: {d} Hz\n", .{ self.frequency, self.rate });
        }

        // Set frequency correction
        ret = rtlsdr.rtlsdr_set_freq_correction(self.dev, @intCast(c_int, self.options.freq_correction));
        if (ret != 0 and ret != -2) {
            std.debug.print("rtlsdr_set_freq_correction(): {d}\n", .{ret});
            return RtlSdrError.InitializationError;
        }

        // Set frequency
        ret = rtlsdr.rtlsdr_set_center_freq64(self.dev, @floatToInt(u64, self.frequency));
        if (ret != 0) {
            std.debug.print("rtlsdr_set_center_freq(): {d}\n", .{ret});
            return RtlSdrError.InitializationError;
        }

        // Set sample rate
        ret = rtlsdr.rtlsdr_set_sample_rate(self.dev, @floatToInt(u32, self.rate));
        if (ret != 0) {
            std.debug.print("rtlsdr_set_sample_rate(): {d}\n", .{ret});
            return RtlSdrError.InitializationError;
        }

        // Set bandwidth
        ret = rtlsdr.rtlsdr_set_tuner_bandwidth(self.dev, if (self.options.bandwidth) |bandwidth| @floatToInt(u32, bandwidth) else 0);
        if (ret != 0) {
            std.debug.print("rtlsdr_set_tuner_bandwidth(): {d}\n", .{ret});
            return RtlSdrError.InitializationError;
        }

        if (self.options.debug) {
            // Get configured frequency
            const frequency = rtlsdr.rtlsdr_get_center_freq64(self.dev);
            // Get configured sample rate
            const sample_rate = rtlsdr.rtlsdr_get_sample_rate(self.dev);

            std.debug.print("[RtlSdrSource] Configured Frequency: {d} Hz, Configured Sample Rate: {d} Hz\n", .{ frequency, sample_rate });
        }

        // Reset endpoint buffer
        ret = rtlsdr.rtlsdr_reset_buffer(self.dev);
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
            const ret = rtlsdr.rtlsdr_set_bias_tee(self.dev, 0);
            if (ret != 0) {
                std.debug.print("rtlsdr_set_bias_tee(): {d}\n", .{ret});
            }
        }

        // Close our device
        if (self.dev) |dev| _ = rtlsdr.rtlsdr_close(dev);

        // Free buffer
        allocator.free(self.buf);
    }

    pub fn process(self: *RtlSdrSource, z: []std.math.Complex(f32)) !ProcessResult {
        // Compute minimum read length
        const len = std.math.min(self.buf.len, z.len & ~@as(usize, MIN_BLOCK_SIZE - 1));

        // Check read length is non-zero (i.e. there is sufficient space in output buffer)
        if (len == 0) {
            return ProcessResult.init(&[0]usize{}, &[1]usize{0});
        }

        // Read samples
        var num_read: c_int = 0;
        const ret = rtlsdr.rtlsdr_read_sync(self.dev, self.buf.ptr, @intCast(c_int, len), &num_read);
        if (ret != 0) {
            std.debug.print("rtlsdr_read_sync(): {d}\n", .{ret});
            return RtlSdrError.ReadError;
        }

        // Convert complex u8 samples to complex float samples
        const num_samples: usize = @divExact(@intCast(usize, num_read), 2);
        var i: usize = 0;
        while (i < num_samples) : (i += 1) {
            z[i] = std.math.Complex(f32).init((@intToFloat(f32, self.buf[2 * i]) - 127.5) * (1.0 / 127.5), (@intToFloat(f32, self.buf[2 * i + 1]) - 127.5) * (1.0 / 127.5));
        }

        return ProcessResult.init(&[0]usize{}, &[1]usize{num_samples});
    }
};
