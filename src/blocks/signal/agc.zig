const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const scalarMul = @import("../../radio.zig").utils.math.scalarMul;

////////////////////////////////////////////////////////////////////////////////
// AGC Block
////////////////////////////////////////////////////////////////////////////////

pub fn AGCBlock(comptime T: type) type {
    if (T != std.math.Complex(f32) and T != f32) @compileError("Only std.math.Complex(f32) and f32 data types supported");

    return struct {
        const Self = @This();

        pub const Mode = enum {
            Slow,
            Fast,
            Custom,
        };

        pub const Options = struct {
            target_dbfs: f32 = -35,
            threshold_dbfs: f32 = -75,
            power_tau: f32 = 1.0,
            gain_tau: f32 = 3.0,
        };

        block: Block,
        options: Options,
        // Parameters
        target: f32 = 0,
        threshold: f32 = 0,
        power_alpha: f32 = 0,
        gain_alpha: f32 = 0,
        // State
        average_power: f32 = 0,
        gain: f32 = 0,

        pub fn init(mode: Mode, options: Options) Self {
            var _options = options;
            switch (mode) {
                .Slow => _options.gain_tau = 3.0,
                .Fast => _options.gain_tau = 0.1,
                .Custom => _options.gain_tau = options.gain_tau,
            }
            return .{ .block = Block.init(@This()), .options = _options };
        }

        pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
            // Linearize logarithmic power target
            self.target = std.math.pow(f32, 10, self.options.target_dbfs / 10);
            // Linearize logarithmic power threshold
            self.threshold = std.math.pow(f32, 10, self.options.threshold_dbfs / 10);
            // Compute normalized alpha for power estimator
            self.power_alpha = 1 / (1 + self.options.power_tau * self.block.getRate(f32));
            // Compute normalized alpha for gain filter
            self.gain_alpha = 1 / (1 + self.options.gain_tau * self.block.getRate(f32));

            // Initialize average power and gain state
            self.average_power = 0.0;
            self.gain = 0.0;
        }

        pub fn process(self: *Self, x: []const T, z: []T) !ProcessResult {
            for (x, 0..) |e, i| {
                // Estimate average power
                const abs_squared = if (T == std.math.Complex(f32)) e.re * e.re + e.im * e.im else e * e;
                self.average_power = (1 - self.power_alpha) * self.average_power + self.power_alpha * abs_squared;

                if (self.average_power >= self.threshold) {
                    // Compute filtered gain
                    self.gain = (1 - self.gain_alpha) * self.gain + self.gain_alpha * (self.target / self.average_power);
                    // Apply sqrt gain
                    z[i] = scalarMul(T, e, std.math.sqrt(self.gain));
                } else {
                    // Pass through without gain
                    z[i] = e;
                }
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/agc.zig");

test "AGCBlock" {
    // Real -63 dBFS cosine input, Fast, -35 dbFS target, -50 dbFS threshold (passthrough)
    {
        var block = AGCBlock(f32).init(.Fast, .{ .target_dbfs = -35, .threshold_dbfs = -50 });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2.0, &[1]type{f32}, .{&vectors.input_cosine}, &[1]type{f32}, .{&vectors.output_real_fast_target_35_threshold_50});
    }

    // Real -63 dBFS cosine input, Fast, -35 dbFS target, -75 dbFS threshold
    {
        var block = AGCBlock(f32).init(.Fast, .{ .target_dbfs = -35, .threshold_dbfs = -75 });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2.0, &[1]type{f32}, .{&vectors.input_cosine}, &[1]type{f32}, .{&vectors.output_real_fast_target_35_threshold_75});
    }

    // Real -63 dBFS cosine input, Slow, -35 dbFS target, -75 dbFS threshold
    {
        var block = AGCBlock(f32).init(.Slow, .{ .target_dbfs = -35, .threshold_dbfs = -75 });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2.0, &[1]type{f32}, .{&vectors.input_cosine}, &[1]type{f32}, .{&vectors.output_real_slow_target_35_threshold_75});
    }

    // Complex -60 dBFS complex exponential input, Fast, -35 dbFS target, -50 dbFS threshold (passthrough)
    {
        var block = AGCBlock(std.math.Complex(f32)).init(.Fast, .{ .target_dbfs = -35, .threshold_dbfs = -50 });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2.0, &[1]type{std.math.Complex(f32)}, .{&vectors.input_exponential}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_complex_fast_target_35_threshold_50});
    }

    // Complex -60 dBFS complex exponential input, Fast, -35 dbFS target, -75 dbFS threshold
    {
        var block = AGCBlock(std.math.Complex(f32)).init(.Fast, .{ .target_dbfs = -35, .threshold_dbfs = -75 });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2.0, &[1]type{std.math.Complex(f32)}, .{&vectors.input_exponential}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_complex_fast_target_35_threshold_75});
    }

    // Complex -60 dBFS complex exponential input, Slow, -35 dbFS target, -75 dbFS threshold
    {
        var block = AGCBlock(std.math.Complex(f32)).init(.Slow, .{ .target_dbfs = -35, .threshold_dbfs = -75 });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2.0, &[1]type{std.math.Complex(f32)}, .{&vectors.input_exponential}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_complex_slow_target_35_threshold_75});
    }
}
