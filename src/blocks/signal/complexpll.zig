// @block ComplexPLLBlock
// @description Generate a phase-locked complex sinusoid to a complex-valued reference
// signal.
//
// $$ y[n] = \text{PLL}(x[n], f_{BW}, f_{min}, f_{max}, M) $$
//
// @category Carrier and Clock Recovery
// @param loop_bandwidth f32 Loop bandwidth in Hz
// @param frequency_range struct{f32,f32} Minimum and maximum frequency range in Hz
// @param options Options Additional options:
//      * `multiplier` (`f32`, frequency multiplier, default 1.0)
// @signature in:Complex(f32) > out:Complex(f32) err:f32
// @usage
// var pll = radio.blocks.ComplexPLLBlock.init(500, .{ 8e3, 12e3 }, .{});
// try top.connect(&src.block, &pll.block);
// try top.connectPort(&pll.block, "out1", &snk.block);
// try top.connectPort(&pll.block, "out2", &err_snk.block);

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// Complex PLL Block
////////////////////////////////////////////////////////////////////////////////

pub const ComplexPLLBlock = struct {
    // Options
    pub const Options = struct {
        multiplier: f32 = 1.0,
    };

    block: Block,

    // Configuration
    loop_bandwidth: f32,
    frequency_range: struct { f32, f32 },
    options: Options,

    // Parameters
    omega_min: f32 = 0,
    omega_max: f32 = 0,
    Kp: f32 = 0,
    Ki: f32 = 0,

    // State
    omega: f32 = 0,
    phi: f32 = 0,

    pub fn init(loop_bandwidth: f32, frequency_range: struct { f32, f32 }, options: Options) ComplexPLLBlock {
        return .{ .block = Block.init(@This()), .loop_bandwidth = loop_bandwidth, .frequency_range = frequency_range, .options = options };
    }

    pub fn initialize(self: *ComplexPLLBlock, _: std.mem.Allocator) !void {
        // Translate frequencies
        self.omega_min = 2 * std.math.pi * (self.frequency_range[0] / self.block.getRate(f32));
        self.omega_max = 2 * std.math.pi * (self.frequency_range[1] / self.block.getRate(f32));

        // Calculate PI gains
        const damping = std.math.sqrt2 / 2.0;
        self.Kp = 1.0 - std.math.exp(-2 * damping * 2 * std.math.pi * self.loop_bandwidth / self.block.getRate(f32));
        self.Ki = 1.0 + std.math.exp(-2 * damping * 2 * std.math.pi * self.loop_bandwidth / self.block.getRate(f32)) -
            2.0 * std.math.exp(-damping * 2 * std.math.pi * self.loop_bandwidth / self.block.getRate(f32)) *
                std.math.cos(2 * std.math.pi * self.loop_bandwidth * std.math.sqrt(1.0 - damping * damping) / self.block.getRate(f32));

        // Initialize state variables
        self.omega = (self.omega_min + self.omega_max) / 2;
        self.phi = 0;
    }

    pub fn process(self: *ComplexPLLBlock, x: []const std.math.Complex(f32), y: []std.math.Complex(f32), err: []f32) !ProcessResult {
        for (x, 0..) |_, i| {
            // Synthesize
            const nco = std.math.Complex(f32){ .re = std.math.cos(self.phi), .im = std.math.sin(self.phi) };
            const nco_multiplied = std.math.Complex(f32){ .re = std.math.cos(self.phi * self.options.multiplier), .im = std.math.sin(self.phi * self.options.multiplier) };

            // Calculate phase error
            const phase_error = std.math.complex.arg(x[i].mul(nco.conjugate()));

            // Loop filter
            self.omega += self.Ki * phase_error;
            self.phi += self.Kp * phase_error + self.omega;

            // Wrap phi to [-pi, pi]
            if (self.phi > std.math.pi) self.phi -= 2 * std.math.pi;
            if (self.phi < -std.math.pi) self.phi += 2 * std.math.pi;

            // Clamp frequency
            self.omega = @max(@min(self.omega, self.omega_max), self.omega_min);

            y[i] = nco_multiplied;
            err[i] = phase_error;
        }

        return ProcessResult.init(&[1]usize{x.len}, &[2]usize{ x.len, x.len });
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockFixture = @import("../../radio.zig").testing.BlockFixture;

test "ComplexPLLBlock" {
    // Synthesize 10 kHz tone at 96 kHz Fs, 0.125 sec duration
    var vector: [12000]std.math.Complex(f32) = undefined;
    for (vector, 0..) |_, i| vector[i] = .{ .re = std.math.cos(2 * std.math.pi * @as(f32, @floatFromInt(i)) * 10e3 / 96e3 + 0.25), .im = std.math.sin(2 * std.math.pi * @as(f32, @floatFromInt(i)) * 10e3 / 96e3 + 0.25) };

    // PLL with 500 Hz loop bandwidth, 8 kHz frequency min, 12 kHz frequency max
    var block = ComplexPLLBlock.init(500, .{ 8e3, 12e3 }, .{});
    var fixture = try BlockFixture(&[1]type{std.math.Complex(f32)}, &[2]type{ std.math.Complex(f32), f32 }).init(&block.block, 96000);
    defer fixture.deinit();

    // Process input
    const outputs = try fixture.process(.{&vector});
    try std.testing.expectEqual(vector.len, outputs[0].len);
    try std.testing.expectEqual(vector.len, outputs[1].len);

    // Check PLL is locked
    try std.testing.expectApproxEqAbs(2 * std.math.pi * 10e3 / 96e3, block.omega, 1e-5);
    try std.testing.expectApproxEqAbs(0.25, block.phi, 1e-3);
    for (outputs[1][vector.len - 1000 .. vector.len]) |err| try std.testing.expect(@abs(err) < 1e-3);
}
