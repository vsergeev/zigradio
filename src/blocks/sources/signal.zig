const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// Signal Source
////////////////////////////////////////////////////////////////////////////////

pub const SignalSource = struct {
    // Supported waveforms
    pub const WaveformFunction = enum {
        Cosine,
        Sine,
        Square,
        Triangle,
        Sawtooth,
        Constant,
    };

    // Options
    pub const Options = struct {
        amplitude: f32 = 1.0,
        offset: f32 = 0,
        phase: f32 = 0,
    };

    block: Block,

    // Configuration
    waveform: WaveformFunction,
    options: Options,
    frequency: f32,
    rate: f64,

    // State
    process_fn: *const fn (self: *SignalSource, z: []f32) anyerror!ProcessResult = undefined,
    phase: f32 = 0,
    omega: f32 = 0,

    pub fn init(waveform: WaveformFunction, frequency: f32, rate: f64, options: Options) SignalSource {
        return .{ .block = Block.init(@This()), .waveform = waveform, .frequency = frequency, .rate = rate, .options = options };
    }

    pub fn setRate(self: *SignalSource, _: f64) !f64 {
        return self.rate;
    }

    pub fn initialize(self: *SignalSource, _: std.mem.Allocator) !void {
        self.process_fn = switch (self.waveform) {
            .Cosine => _processCosine,
            .Sine => _processSine,
            .Square => _processSquare,
            .Triangle => _processTriangle,
            .Sawtooth => _processSawtooth,
            .Constant => _processConstant,
        };

        self.phase = self.options.phase;
        self.omega = 2 * std.math.pi * (self.frequency / self.block.getRate(f32));
    }

    pub fn _processCosine(self: *SignalSource, z: []f32) !ProcessResult {
        for (z) |*e| {
            e.* = std.math.cos(self.phase) * self.options.amplitude + self.options.offset;
            self.phase += self.omega;
            self.phase = if (self.phase >= 2 * std.math.pi) self.phase - 2 * std.math.pi else self.phase;
        }

        return ProcessResult.init(&[0]usize{}, &[1]usize{z.len});
    }

    pub fn _processSine(self: *SignalSource, z: []f32) !ProcessResult {
        for (z) |*e| {
            e.* = std.math.sin(self.phase) * self.options.amplitude + self.options.offset;
            self.phase += self.omega;
            self.phase = if (self.phase >= 2 * std.math.pi) self.phase - 2 * std.math.pi else self.phase;
        }

        return ProcessResult.init(&[0]usize{}, &[1]usize{z.len});
    }

    pub fn _processSquare(self: *SignalSource, z: []f32) !ProcessResult {
        for (z) |*e| {
            if (self.phase < std.math.pi) {
                e.* = self.options.amplitude + self.options.offset;
            } else {
                e.* = -1 * self.options.amplitude + self.options.offset;
            }
            self.phase += self.omega;
            self.phase = if (self.phase >= 2 * std.math.pi) self.phase - 2 * std.math.pi else self.phase;
        }

        return ProcessResult.init(&[0]usize{}, &[1]usize{z.len});
    }

    pub fn _processTriangle(self: *SignalSource, z: []f32) !ProcessResult {
        for (z) |*e| {
            if (self.phase < std.math.pi) {
                e.* = (1.0 - (2.0 / std.math.pi) * self.phase) * self.options.amplitude + self.options.offset;
            } else {
                e.* = (-1.0 + (2.0 / std.math.pi) * (self.phase - std.math.pi)) * self.options.amplitude + self.options.offset;
            }
            self.phase += self.omega;
            self.phase = if (self.phase >= 2 * std.math.pi) self.phase - 2 * std.math.pi else self.phase;
        }

        return ProcessResult.init(&[0]usize{}, &[1]usize{z.len});
    }

    pub fn _processSawtooth(self: *SignalSource, z: []f32) !ProcessResult {
        for (z) |*e| {
            e.* = (-1.0 + (1.0 / std.math.pi) * self.phase) * self.options.amplitude + self.options.offset;
            self.phase += self.omega;
            self.phase = if (self.phase >= 2 * std.math.pi) self.phase - 2 * std.math.pi else self.phase;
        }

        return ProcessResult.init(&[0]usize{}, &[1]usize{z.len});
    }

    pub fn _processConstant(self: *SignalSource, z: []f32) !ProcessResult {
        for (z) |*e| {
            e.* = self.options.amplitude;
        }

        return ProcessResult.init(&[0]usize{}, &[1]usize{z.len});
    }

    pub fn process(self: *SignalSource, z: []f32) !ProcessResult {
        return self.process_fn(self, z);
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/sources/signal.zig");

test "SignalSource" {
    // Cosine frequency 50, sample rate 1000, ampltiude 1.00, offset 0.00, phase 0.0000
    {
        var block = SignalSource.init(SignalSource.WaveformFunction.Cosine, 50, 1000.0, .{ .amplitude = 1.0, .offset = 0.0, .phase = 0.0 });
        var tester = BlockTester.init(&block.block, 1.5e-5);
        try tester.checkSource(&[1]type{f32}, .{&vectors.cosine_frequency_50_rate_1000_ampltiude_1_offset_0_phase_0});
    }

    // Cosine frequency 100, sample rate 1000, ampltiude 2.50, offset -0.50, phase 0.7854
    {
        var block = SignalSource.init(SignalSource.WaveformFunction.Cosine, 100, 1000.0, .{ .amplitude = 2.5, .offset = -0.5, .phase = 0.7853981633974483 });
        var tester = BlockTester.init(&block.block, 1.5e-5);
        try tester.checkSource(&[1]type{f32}, .{&vectors.cosine_frequency_100_rate_1000_ampltiude_2_5_offset_neg_0_50_phase_0_7854});
    }

    // Sine frequency 50, sample rate 1000, ampltiude 1.00, offset 0.00, phase 0.0000
    {
        var block = SignalSource.init(SignalSource.WaveformFunction.Sine, 50, 1000.0, .{ .amplitude = 1.0, .offset = 0.0, .phase = 0.0 });
        var tester = BlockTester.init(&block.block, 1.5e-5);
        try tester.checkSource(&[1]type{f32}, .{&vectors.sine_frequency_50_rate_1000_ampltiude_1_offset_0_phase_0});
    }

    // Sine frequency 100, sample rate 1000, ampltiude 2.50, offset -0.50, phase 0.7854
    {
        var block = SignalSource.init(SignalSource.WaveformFunction.Sine, 100, 1000.0, .{ .amplitude = 2.5, .offset = -0.5, .phase = 0.7853981633974483 });
        var tester = BlockTester.init(&block.block, 1.5e-5);
        try tester.checkSource(&[1]type{f32}, .{&vectors.sine_frequency_100_rate_1000_ampltiude_2_5_offset_neg_0_50_phase_0_7854});
    }

    // Square frequency 50, sample rate 1000, ampltiude 1.00, offset 0.00, phase 0.0000
    {
        var block = SignalSource.init(SignalSource.WaveformFunction.Square, 50, 1000.0, .{ .amplitude = 1.0, .offset = 0.0, .phase = 0.0 });
        var tester = BlockTester.init(&block.block, 1.5e-5);
        try tester.checkSource(&[1]type{f32}, .{&vectors.square_frequency_50_rate_1000_ampltiude_1_offset_0_phase_0});
    }

    // Square frequency 100, sample rate 1000, ampltiude 2.50, offset -0.50, phase 0.7854
    {
        var block = SignalSource.init(SignalSource.WaveformFunction.Square, 100, 1000.0, .{ .amplitude = 2.5, .offset = -0.5, .phase = 0.7853981633974483 });
        var tester = BlockTester.init(&block.block, 1.5e-5);
        try tester.checkSource(&[1]type{f32}, .{&vectors.square_frequency_100_rate_1000_ampltiude_2_5_offset_neg_0_50_phase_0_7854});
    }

    // Triangle frequency 50, sample rate 1000, ampltiude 1.00, offset 0.00, phase 0.0000
    {
        var block = SignalSource.init(SignalSource.WaveformFunction.Triangle, 50, 1000.0, .{ .amplitude = 1.0, .offset = 0.0, .phase = 0.0 });
        var tester = BlockTester.init(&block.block, 1.5e-5);
        try tester.checkSource(&[1]type{f32}, .{&vectors.triangle_frequency_50_rate_1000_ampltiude_1_offset_0_phase_0});
    }

    // Triangle frequency 100, sample rate 1000, ampltiude 2.50, offset -0.50, phase 0.7854
    {
        var block = SignalSource.init(SignalSource.WaveformFunction.Triangle, 100, 1000.0, .{ .amplitude = 2.5, .offset = -0.5, .phase = 0.7853981633974483 });
        var tester = BlockTester.init(&block.block, 1.5e-5);
        try tester.checkSource(&[1]type{f32}, .{&vectors.triangle_frequency_100_rate_1000_ampltiude_2_5_offset_neg_0_50_phase_0_7854});
    }

    // Sawtooth frequency 50, sample rate 1000, ampltiude 1.00, offset 0.00, phase 0.0000
    {
        var block = SignalSource.init(SignalSource.WaveformFunction.Sawtooth, 50, 1000.0, .{ .amplitude = 1.0, .offset = 0.0, .phase = 0.0 });
        var tester = BlockTester.init(&block.block, 1.5e-5);
        try tester.checkSource(&[1]type{f32}, .{&vectors.sawtooth_frequency_50_rate_1000_ampltiude_1_offset_0_phase_0});
    }

    // Sawtooth frequency 100, sample rate 1000, ampltiude 2.50, offset -0.50, phase 0.7854
    {
        var block = SignalSource.init(SignalSource.WaveformFunction.Sawtooth, 100, 1000.0, .{ .amplitude = 2.5, .offset = -0.5, .phase = 0.7853981633974483 });
        var tester = BlockTester.init(&block.block, 1.5e-5);
        try tester.checkSource(&[1]type{f32}, .{&vectors.sawtooth_frequency_100_rate_1000_ampltiude_2_5_offset_neg_0_50_phase_0_7854});
    }

    // Constant frequency 50, sample rate 1000, ampltiude 1.00, offset 0.00, phase 0.0000
    {
        var block = SignalSource.init(SignalSource.WaveformFunction.Constant, 50, 1000.0, .{ .amplitude = 1.0, .offset = 0.0, .phase = 0.0 });
        var tester = BlockTester.init(&block.block, 1.5e-5);
        try tester.checkSource(&[1]type{f32}, .{&vectors.constant_frequency_50_rate_1000_ampltiude_1_offset_0_phase_0});
    }

    // Constant frequency 100, sample rate 1000, ampltiude 2.50, offset -0.50, phase 0.7854
    {
        var block = SignalSource.init(SignalSource.WaveformFunction.Constant, 100, 1000.0, .{ .amplitude = 2.5, .offset = -0.5, .phase = 0.7853981633974483 });
        var tester = BlockTester.init(&block.block, 1.5e-5);
        try tester.checkSource(&[1]type{f32}, .{&vectors.constant_frequency_100_rate_1000_ampltiude_2_5_offset_neg_0_50_phase_0_7854});
    }
}
