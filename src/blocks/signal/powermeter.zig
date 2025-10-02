// @block PowerMeterBlock
// @description Compute the average power of a signal in dBFS, using an
// exponential moving average.
// @category Level control
// @ctparam T type Complex(f32), f32
// @param report_interval_ms f32 Reporting interval in milliseconds
// @param options Options Additional options:
//      * `power_tau` (`f32`, power estimator time constant, default 0.5)
// @signature in1:T > out1:f32
// @usage
// var power_meter = radio.blocks.PowerMeterBlock(std.math.Complex(f32)).init(50, .{});

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const scalarMul = @import("../../radio.zig").utils.math.scalarMul;

////////////////////////////////////////////////////////////////////////////////
// Power Meter Block
////////////////////////////////////////////////////////////////////////////////

pub fn PowerMeterBlock(comptime T: type) type {
    if (T != std.math.Complex(f32) and T != f32) @compileError("Only std.math.Complex(f32) and f32 data types supported");

    return struct {
        const Self = @This();

        pub const Options = struct {
            power_tau: f32 = 0.5,
        };

        block: Block,
        report_interval_ms: f32,
        options: Options,
        // Parameters
        power_alpha: f32 = 0,
        report_interval_samples: usize = 0,
        // State
        average_power: f32 = 0,
        report_interval_index: usize = 0,
        reset_power: bool = false,

        pub fn init(report_interval_ms: f32, options: Options) Self {
            return .{ .block = Block.init(@This()), .report_interval_ms = report_interval_ms, .options = options };
        }

        pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
            self.average_power = 0.0;
            self.report_interval_index = 0;
        }

        pub fn setRate(self: *Self, upstream_rate: f64) !f64 {
            // Compute normalized alpha for power estimator
            self.power_alpha = 1 / (1 + self.options.power_tau * @as(f32, @floatCast(upstream_rate)));
            // Compute report interval in terms of samples
            self.report_interval_samples = @intFromFloat((upstream_rate * self.report_interval_ms) / 1000.0);

            // Return report interval as a rate
            return 1000.0 / @as(f64, @floatCast(self.report_interval_ms));
        }

        pub fn process(self: *Self, x: []const T, z: []f32) !ProcessResult {
            var output_index: usize = 0;

            // Emit a NaN on reset
            if (self.reset_power) {
                z[0] = std.math.nan(f32);
                output_index += 1;
                self.reset_power = false;
            }

            for (x) |e| {
                // Estimate average power
                const abs_squared = if (T == std.math.Complex(f32)) e.re * e.re + e.im * e.im else e * e;
                self.average_power = (1 - self.power_alpha) * self.average_power + self.power_alpha * abs_squared;

                // Report average power in dBFS every report interval samples
                self.report_interval_index = (self.report_interval_index + 1) % self.report_interval_samples;
                if (self.report_interval_index == 0) {
                    z[output_index] = 10 * std.math.log10(self.average_power);
                    output_index += 1;
                }
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{output_index});
        }

        pub fn reset(self: *Self) void {
            self.reset_power = true;
            self.average_power = 0;
            self.report_interval_index = 0;
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockFixture = @import("../../radio.zig").testing.BlockFixture;

const vectors = @import("../../vectors/blocks/signal/powermeter.zig");

test "PowerMeterBlock" {
    // Real -49 dBFS cosine input
    {
        var block = PowerMeterBlock(f32).init(50, .{});
        var fixture = try BlockFixture(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1000);
        defer fixture.deinit();

        for (0..25) |_| {
            const outputs = try fixture.process(.{&vectors.input_cosine_49});
            try std.testing.expectEqual(2, outputs[0].len);
        }

        const outputs = try fixture.process(.{&vectors.input_cosine_49});
        try std.testing.expectApproxEqAbs(-49, outputs[0][1], 0.1);
    }

    // Complex -46 dBFS exponential input
    {
        var block = PowerMeterBlock(std.math.Complex(f32)).init(50, .{});
        var fixture = try BlockFixture(&[1]type{std.math.Complex(f32)}, &[1]type{f32}).init(&block.block, 1000);
        defer fixture.deinit();

        for (0..25) |_| {
            const outputs = try fixture.process(.{&vectors.input_exponential_46});
            try std.testing.expectEqual(2, outputs[0].len);
        }

        const outputs = try fixture.process(.{&vectors.input_exponential_46});
        try std.testing.expectApproxEqAbs(-46, outputs[0][1], 0.1);
    }
}

test "PowerMeterBlock reset" {
    var block = PowerMeterBlock(f32).init(50, .{});
    var fixture = try BlockFixture(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1000);
    defer fixture.deinit();

    const outputs1 = try fixture.process(.{&vectors.input_cosine_49});
    try std.testing.expectEqual(2, outputs1[0].len);

    var outputs: [2]f32 = undefined;
    @memcpy(&outputs, outputs1[0]);

    block.reset();

    const outputs2 = try fixture.process(.{&vectors.input_cosine_49});
    try std.testing.expectEqual(3, outputs2[0].len);

    try std.testing.expect(std.math.isNan(outputs2[0][0]));
    try std.testing.expectEqual(outputs[0], outputs2[0][1]);
    try std.testing.expectEqual(outputs[1], outputs2[0][2]);
}
