// @block FrequencyDiscriminatorBlock
// @description Compute the instantaneous frequency of a complex-valued input
// signal. This is a method of frequency demodulation.
//
// $$ y[n] = \frac{\text{arg}(x[n] \; x^*[n-1])}{2 \pi k} $$
//
// @category Demodulation
// @param deviation f32 Frequency deviation in Hz
// @signature in1:Complex(f32) > out1:f32
// @usage
// var demod = radio.blocks.FrequencyDiscriminatorBlock.init(5e3);

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

////////////////////////////////////////////////////////////////////////////////
// Frequency Discriminator Block
////////////////////////////////////////////////////////////////////////////////

pub const FrequencyDiscriminatorBlock = struct {
    block: Block,
    deviation: f32,
    impl: union(enum) {
        none,
        volk: _FrequencyDiscriminatorBlockVolkImpl,
        liquid: _FrequencyDiscriminatorBlockLiquidImpl,
        zig: _FrequencyDiscriminatorBlockZigImpl,
    } = .none,

    pub fn init(deviation: f32) FrequencyDiscriminatorBlock {
        return .{ .block = Block.init(@This()), .deviation = deviation };
    }

    pub fn initialize(self: *FrequencyDiscriminatorBlock, allocator: std.mem.Allocator) !void {
        if (platform.libs.volk != null) {
            self.impl = .{ .volk = .{ .parent = self } };
        } else if (platform.libs.liquid != null) {
            // Prefer pure Zig implementation for now (benchmarks better)
            self.impl = .{ .zig = .{ .parent = self } };
        } else {
            self.impl = .{ .zig = .{ .parent = self } };
        }

        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| try impl.initialize(allocator),
        }
    }

    pub fn deinitialize(self: *FrequencyDiscriminatorBlock, allocator: std.mem.Allocator) void {
        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| impl.deinitialize(allocator),
        }
    }

    pub fn process(self: *FrequencyDiscriminatorBlock, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| return impl.process(x, z),
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Frequency Discriminator Implementation (Volk)
////////////////////////////////////////////////////////////////////////////////

const lv_32fc_t = extern struct {
    real: f32,
    imag: f32,
};
var volk_32fc_x2_multiply_conjugate_32fc: *const *const fn ([*c]lv_32fc_t, [*c]const lv_32fc_t, [*c]const lv_32fc_t, c_uint) callconv(.c) void = undefined;
var volk_32fc_s32f_atan2_32f: *const *const fn ([*c]f32, [*c]const lv_32fc_t, f32, c_uint) callconv(.c) void = undefined;
var volk_loaded: bool = false;

pub const _FrequencyDiscriminatorBlockVolkImpl = struct {
    parent: *const FrequencyDiscriminatorBlock,
    tmp: std.array_list.Managed(std.math.Complex(f32)) = undefined,
    prev_sample: std.math.Complex(f32) = .{ .re = 0, .im = 0 },
    normalization: f32 = 0,

    pub fn initialize(self: *_FrequencyDiscriminatorBlockVolkImpl, allocator: std.mem.Allocator) !void {
        if (!volk_loaded) {
            volk_32fc_x2_multiply_conjugate_32fc = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_x2_multiply_conjugate_32fc), "volk_32fc_x2_multiply_conjugate_32fc") orelse return error.LookupFail;
            volk_32fc_s32f_atan2_32f = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_s32f_atan2_32f), "volk_32fc_s32f_atan2_32f") orelse return error.LookupFail;
            volk_loaded = true;
        }

        self.tmp = std.array_list.Managed(std.math.Complex(f32)).init(allocator);
        try self.tmp.append(.{ .re = 0, .im = 0 });
        self.prev_sample = .{ .re = 0, .im = 0 };
        self.normalization = (2 * std.math.pi * self.parent.deviation) / self.parent.block.getRate(f32);

        if (platform.debug.enabled) std.debug.print("[FrequencyDiscriminatorBlock] Using VOLK implementation\n", .{});
    }

    pub fn deinitialize(self: *_FrequencyDiscriminatorBlockVolkImpl, _: std.mem.Allocator) void {
        self.tmp.deinit();
    }

    pub fn process(self: *_FrequencyDiscriminatorBlockVolkImpl, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        // Resize temporary vector
        try self.tmp.resize(x.len);

        // Multiply element-wise of samples by conjugate of previous samples
        //      [a b c d e f g h] * ~[p a b c d e f g]
        self.tmp.items[0] = x[0].mul(self.prev_sample.conjugate());
        volk_32fc_x2_multiply_conjugate_32fc.*(@ptrCast(self.tmp.items[1..].ptr), @ptrCast(x[1..].ptr), @ptrCast(x.ptr), @intCast(x.len - 1));

        // Compute element-wise atan2 of multiplied samples
        volk_32fc_s32f_atan2_32f.*(z.ptr, @ptrCast(self.tmp.items.ptr), self.normalization, @intCast(x.len));

        // Save last sample of x to be the next previous sample
        self.prev_sample = x[x.len - 1];

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Frequency Discriminator Implementation (Liquid)
////////////////////////////////////////////////////////////////////////////////

const liquid_float_complex = extern struct {
    real: f32,
    imag: f32,
};

const struct_freqdem_s = opaque {};
const freqdem = ?*struct_freqdem_s;
var freqdem_create: *const fn (_kf: f32) callconv(.c) freqdem = undefined;
var freqdem_destroy: *const fn (_q: freqdem) callconv(.c) c_int = undefined;
var freqdem_demodulate_block: *const fn (_q: freqdem, _r: [*c]liquid_float_complex, _n: c_uint, _m: [*c]f32) callconv(.c) c_int = undefined;
var liquid_loaded: bool = false;

pub const _FrequencyDiscriminatorBlockLiquidImpl = struct {
    parent: *const FrequencyDiscriminatorBlock,
    freqdem: freqdem = undefined,

    pub fn initialize(self: *_FrequencyDiscriminatorBlockLiquidImpl, _: std.mem.Allocator) !void {
        if (!liquid_loaded) {
            freqdem_create = platform.libs.liquid.?.lookup(@TypeOf(freqdem_create), "freqdem_create") orelse return error.LookupFail;
            freqdem_destroy = platform.libs.liquid.?.lookup(@TypeOf(freqdem_destroy), "freqdem_destroy") orelse return error.LookupFail;
            freqdem_demodulate_block = platform.libs.liquid.?.lookup(@TypeOf(freqdem_demodulate_block), "freqdem_demodulate_block") orelse return error.LookupFail;
            liquid_loaded = true;
        }

        self.freqdem = freqdem_create(self.parent.deviation / self.parent.block.getRate(f32));
        if (self.freqdem == null) return error.OutOfMemory;

        if (platform.debug.enabled) std.debug.print("[FrequencyDiscriminatorBlock] Using liquid-dsp implementation\n", .{});
    }

    pub fn deinitialize(self: *_FrequencyDiscriminatorBlockLiquidImpl, _: std.mem.Allocator) void {
        _ = freqdem_destroy(self.freqdem);
    }

    pub fn process(self: *_FrequencyDiscriminatorBlockLiquidImpl, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        _ = freqdem_demodulate_block(self.freqdem, @ptrCast(@constCast(x.ptr)), @intCast(x.len), @ptrCast(z.ptr));

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Frequency Discriminator Implementation (Zig)
////////////////////////////////////////////////////////////////////////////////

pub const _FrequencyDiscriminatorBlockZigImpl = struct {
    parent: *const FrequencyDiscriminatorBlock,
    prev_sample: std.math.Complex(f32) = .{ .re = 0, .im = 0 },
    gain: f32 = 0,

    pub fn initialize(self: *_FrequencyDiscriminatorBlockZigImpl, _: std.mem.Allocator) !void {
        self.prev_sample = .{ .re = 0, .im = 0 };

        self.gain = self.parent.block.getRate(f32) / (2 * std.math.pi * self.parent.deviation);

        if (platform.debug.enabled) std.debug.print("[FrequencyDiscriminatorBlock] Using Zig implementation\n", .{});
    }

    pub fn deinitialize(_: *_FrequencyDiscriminatorBlockZigImpl, _: std.mem.Allocator) void {}

    pub fn process(self: *_FrequencyDiscriminatorBlockZigImpl, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        for (x, 0..) |_, i| {
            const tmp = x[i].mul((if (i == 0) self.prev_sample else x[i - 1]).conjugate());
            z[i] = std.math.complex.arg(tmp) * self.gain;
        }

        self.prev_sample = x[x.len - 1];

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/frequencydiscriminator.zig");

test "FrequencyDiscriminatorBlock" {
    // Deviation 0.2
    {
        var block = FrequencyDiscriminatorBlock.init(0.2);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{f32}).init(&block.block, 1e-5);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_modulation_index_0_2}, .{});
    }

    // Deviation 0.4
    {
        var block = FrequencyDiscriminatorBlock.init(0.4);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{f32}).init(&block.block, 1e-5);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_modulation_index_0_4}, .{});
    }
}
