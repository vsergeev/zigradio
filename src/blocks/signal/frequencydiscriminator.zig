const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

////////////////////////////////////////////////////////////////////////////////
// Frequency Discriminator Block
////////////////////////////////////////////////////////////////////////////////

pub const FrequencyDiscriminatorBlock = struct {
    block: Block,
    gain: f32,
    impl: union(enum) {
        none,
        volk: _FrequencyDiscriminatorBlockVolkImpl,
        zig: _FrequencyDiscriminatorBlockZigImpl,
    } = .none,

    pub fn init(modulation_index: f32) FrequencyDiscriminatorBlock {
        return .{ .block = Block.init(@This()), .gain = 2 * std.math.pi * modulation_index };
    }

    pub fn initialize(self: *FrequencyDiscriminatorBlock, allocator: std.mem.Allocator) !void {
        if (platform.libs.volk != null) {
            self.impl = .{ .volk = .{ .parent = self } };
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
var volk_32fc_x2_multiply_conjugate_32fc: *const *const fn ([*c]lv_32fc_t, [*c]const lv_32fc_t, [*c]const lv_32fc_t, c_uint) callconv(.C) void = undefined;
var volk_32fc_s32f_atan2_32f: *const *const fn ([*c]f32, [*c]const lv_32fc_t, f32, c_uint) callconv(.C) void = undefined;
var volk_loaded: bool = false;

pub const _FrequencyDiscriminatorBlockVolkImpl = struct {
    parent: *const FrequencyDiscriminatorBlock,
    tmp: std.ArrayList(std.math.Complex(f32)) = undefined,
    prev_sample: std.math.Complex(f32) = .{ .re = 0, .im = 0 },

    pub fn initialize(self: *_FrequencyDiscriminatorBlockVolkImpl, allocator: std.mem.Allocator) !void {
        if (!volk_loaded) {
            volk_32fc_x2_multiply_conjugate_32fc = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_x2_multiply_conjugate_32fc), "volk_32fc_x2_multiply_conjugate_32fc") orelse return error.LookupFail;
            volk_32fc_s32f_atan2_32f = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_s32f_atan2_32f), "volk_32fc_s32f_atan2_32f") orelse return error.LookupFail;
            volk_loaded = true;
        }

        self.tmp = std.ArrayList(std.math.Complex(f32)).init(allocator);
        try self.tmp.append(.{ .re = 0, .im = 0 });
        self.prev_sample = .{ .re = 0, .im = 0 };

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
        volk_32fc_s32f_atan2_32f.*(z.ptr, @ptrCast(self.tmp.items.ptr), self.parent.gain, @intCast(x.len));

        // Save last sample of x to be the next previous sample
        self.prev_sample = x[x.len - 1];

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Frequency Discriminator Implementation (Zig)
////////////////////////////////////////////////////////////////////////////////

pub const _FrequencyDiscriminatorBlockZigImpl = struct {
    parent: *const FrequencyDiscriminatorBlock,
    prev_sample: std.math.Complex(f32) = .{ .re = 0, .im = 0 },

    pub fn initialize(self: *_FrequencyDiscriminatorBlockZigImpl, _: std.mem.Allocator) !void {
        self.prev_sample = .{ .re = 0, .im = 0 };

        if (platform.debug.enabled) std.debug.print("[FrequencyDiscriminatorBlock] Using Zig implementation\n", .{});
    }

    pub fn deinitialize(_: *_FrequencyDiscriminatorBlockZigImpl, _: std.mem.Allocator) void {}

    pub fn process(self: *_FrequencyDiscriminatorBlockZigImpl, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        for (x, 0..) |_, i| {
            const tmp = x[i].mul((if (i == 0) self.prev_sample else x[i - 1]).conjugate());
            z[i] = std.math.atan2(tmp.im, tmp.re) * (1.0 / self.parent.gain);
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
    // Modulation index 1.0
    {
        var block = FrequencyDiscriminatorBlock.init(1.0);
        var tester = BlockTester.init(&block.block, 1e-5);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{f32}, .{&vectors.output_modulation_index_1});
    }

    // Modulation index 5.0
    {
        var block = FrequencyDiscriminatorBlock.init(5.0);
        var tester = BlockTester.init(&block.block, 1e-5);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{f32}, .{&vectors.output_modulation_index_5});
    }
}
