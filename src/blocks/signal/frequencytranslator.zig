const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

////////////////////////////////////////////////////////////////////////////////
// Frequency Translator Block
////////////////////////////////////////////////////////////////////////////////

pub const FrequencyTranslatorBlock = struct {
    block: Block,
    offset: f32,
    impl: union(enum) {
        none,
        volk: _FrequencyTranslatorBlockVolkImpl,
        liquid: _FrequencyTranslatorBlockLiquidImpl,
        zig: _FrequencyTranslatorBlockZigImpl,
    } = .none,

    pub fn init(offset: f32) FrequencyTranslatorBlock {
        return .{ .block = Block.init(@This()), .offset = offset };
    }

    pub fn initialize(self: *FrequencyTranslatorBlock, allocator: std.mem.Allocator) !void {
        if (platform.libs.volk != null) {
            self.impl = .{ .volk = .{ .parent = self } };
        } else if (platform.libs.liquid != null) {
            self.impl = .{ .liquid = .{ .parent = self } };
        } else {
            self.impl = .{ .zig = .{ .parent = self } };
        }

        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| try impl.initialize(allocator),
        }
    }

    pub fn deinitialize(self: *FrequencyTranslatorBlock, allocator: std.mem.Allocator) void {
        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| impl.deinitialize(allocator),
        }
    }

    pub fn process(self: *FrequencyTranslatorBlock, x: []const std.math.Complex(f32), z: []std.math.Complex(f32)) !ProcessResult {
        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| return impl.process(x, z),
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Frequency Translator Implementation (Volk)
////////////////////////////////////////////////////////////////////////////////

const lv_32fc_t = extern struct {
    real: f32,
    imag: f32,
};
var volk_32fc_s32fc_x2_rotator_32fc: *const *const fn ([*c]lv_32fc_t, [*c]const lv_32fc_t, lv_32fc_t, [*c]lv_32fc_t, c_uint) callconv(.C) void = undefined;
var volk_loaded: bool = false;

pub const _FrequencyTranslatorBlockVolkImpl = struct {
    parent: *const FrequencyTranslatorBlock,
    rotation: std.math.Complex(f32) = .{ .re = 0, .im = 0 },
    phi: std.math.Complex(f32) = .{ .re = 0, .im = 0 },

    pub fn initialize(self: *_FrequencyTranslatorBlockVolkImpl, _: std.mem.Allocator) !void {
        if (!volk_loaded) {
            volk_32fc_s32fc_x2_rotator_32fc = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_s32fc_x2_rotator_32fc), "volk_32fc_s32fc_x2_rotator_32fc") orelse return error.LookupFail;
            volk_loaded = true;
        }

        const omega = 2 * std.math.pi * (self.parent.offset / self.parent.block.getRate(f32));
        self.rotation = std.math.Complex(f32).init(std.math.cos(omega), std.math.sin(omega));
        self.phi = std.math.Complex(f32).init(1, 0);

        if (platform.debug.enabled) std.debug.print("[FrequencyTranslatorBlock] Using VOLK implementation\n", .{});
    }

    pub fn deinitialize(_: *_FrequencyTranslatorBlockVolkImpl, _: std.mem.Allocator) void {}

    pub fn process(self: *_FrequencyTranslatorBlockVolkImpl, x: []const std.math.Complex(f32), z: []std.math.Complex(f32)) !ProcessResult {
        volk_32fc_s32fc_x2_rotator_32fc.*(@ptrCast(z.ptr), @ptrCast(x.ptr), lv_32fc_t{ .real = self.rotation.re, .imag = self.rotation.im }, @ptrCast(&self.phi), @intCast(x.len));
        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Frequency Translator Implementation (Liquid)
////////////////////////////////////////////////////////////////////////////////

const liquid_float_complex = extern struct {
    real: f32,
    imag: f32,
};

const LIQUID_NCO: c_int = 0;
const LIQUID_VCO: c_int = 1;

const liquid_ncotype = c_uint;
const struct_nco_crcf_s = opaque {};
const nco_crcf = ?*struct_nco_crcf_s;
var nco_crcf_create: *const fn (_type: liquid_ncotype) nco_crcf = undefined;
var nco_crcf_destroy: *const fn (_q: nco_crcf) c_int = undefined;
var nco_crcf_set_frequency: *const fn (_q: nco_crcf, _dtheta: f32) c_int = undefined;
var nco_crcf_set_phase: *const fn (_q: nco_crcf, _phi: f32) c_int = undefined;
var nco_crcf_mix_block_up: *const fn (_q: nco_crcf, _x: [*c]liquid_float_complex, _y: [*c]liquid_float_complex, _n: c_uint) c_int = undefined;
var liquid_loaded: bool = false;

pub const _FrequencyTranslatorBlockLiquidImpl = struct {
    parent: *const FrequencyTranslatorBlock,
    nco: nco_crcf = undefined,

    pub fn initialize(self: *_FrequencyTranslatorBlockLiquidImpl, _: std.mem.Allocator) !void {
        if (!liquid_loaded) {
            nco_crcf_create = platform.libs.liquid.?.lookup(@TypeOf(nco_crcf_create), "nco_crcf_create") orelse return error.LookupFail;
            nco_crcf_destroy = platform.libs.liquid.?.lookup(@TypeOf(nco_crcf_destroy), "nco_crcf_destroy") orelse return error.LookupFail;
            nco_crcf_set_frequency = platform.libs.liquid.?.lookup(@TypeOf(nco_crcf_set_frequency), "nco_crcf_set_frequency") orelse return error.LookupFail;
            nco_crcf_set_phase = platform.libs.liquid.?.lookup(@TypeOf(nco_crcf_set_phase), "nco_crcf_set_phase") orelse return error.LookupFail;
            nco_crcf_mix_block_up = platform.libs.liquid.?.lookup(@TypeOf(nco_crcf_mix_block_up), "nco_crcf_mix_block_up") orelse return error.LookupFail;
            liquid_loaded = true;
        }

        self.nco = nco_crcf_create(LIQUID_VCO);

        if (self.nco == null) return error.OutOfMemory;

        _ = nco_crcf_set_frequency(self.nco, 2 * std.math.pi * (self.parent.offset / self.parent.block.getRate(f32)));
        _ = nco_crcf_set_phase(self.nco, 0.0);

        if (platform.debug.enabled) std.debug.print("[FrequencyTranslatorBlock] Using liquid-dsp implementation\n", .{});
    }

    pub fn deinitialize(self: *_FrequencyTranslatorBlockLiquidImpl, _: std.mem.Allocator) void {
        _ = nco_crcf_destroy(self.nco);
    }

    pub fn process(self: *_FrequencyTranslatorBlockLiquidImpl, x: []const std.math.Complex(f32), z: []std.math.Complex(f32)) !ProcessResult {
        _ = nco_crcf_mix_block_up(self.nco, @ptrCast(@constCast(x.ptr)), @ptrCast(z.ptr), @intCast(x.len));

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Frequency Translator Implementation (Zig)
////////////////////////////////////////////////////////////////////////////////

pub const _FrequencyTranslatorBlockZigImpl = struct {
    parent: *const FrequencyTranslatorBlock,
    omega: f32 = 0,
    phase: f32 = 0,

    pub fn initialize(self: *_FrequencyTranslatorBlockZigImpl, _: std.mem.Allocator) !void {
        self.omega = 2 * std.math.pi * (self.parent.offset / self.parent.block.getRate(f32));
        self.phase = 0;

        if (platform.debug.enabled) std.debug.print("[FrequencyTranslatorBlock] Using Zig implementation\n", .{});
    }

    pub fn deinitialize(_: *_FrequencyTranslatorBlockZigImpl, _: std.mem.Allocator) void {}

    pub fn process(self: *_FrequencyTranslatorBlockZigImpl, x: []const std.math.Complex(f32), z: []std.math.Complex(f32)) !ProcessResult {
        for (x, 0..) |_, i| {
            z[i] = x[i].mul(.{ .re = std.math.cos(self.phase), .im = std.math.sin(self.phase) });
            self.phase += self.omega;
        }

        while (@abs(self.phase) > 2 * std.math.pi) {
            self.phase -= std.math.sign(self.omega) * 2 * std.math.pi;
        }

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/frequencytranslator.zig");

test "FrequencyTranslatorBlock" {
    // Rotate by +0.2
    {
        var block = FrequencyTranslatorBlock.init(0.2);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 5e-3);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_pos_0_2}, .{});
    }

    // Rotate by -0.2
    {
        var block = FrequencyTranslatorBlock.init(-0.2);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 5e-3);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_neg_0_2}, .{});
    }
}
