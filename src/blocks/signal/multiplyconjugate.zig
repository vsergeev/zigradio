const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

////////////////////////////////////////////////////////////////////////////////
// Multiply Conjugate Block
////////////////////////////////////////////////////////////////////////////////

pub const MultiplyConjugateBlock = struct {
    block: Block,
    impl: union(enum) {
        none,
        volk: _MultiplyConjugateBlockVolkImpl,
        zig: _MultiplyConjugateBlockZigImpl,
    } = .none,

    pub fn init() MultiplyConjugateBlock {
        return .{ .block = Block.init(@This()) };
    }

    pub fn initialize(self: *MultiplyConjugateBlock, allocator: std.mem.Allocator) !void {
        if (platform.libs.volk != null) {
            self.impl = .{ .volk = .{} };
        } else {
            self.impl = .{ .zig = .{} };
        }

        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| try impl.initialize(allocator),
        }
    }

    pub fn deinitialize(self: *MultiplyConjugateBlock, allocator: std.mem.Allocator) void {
        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| impl.deinitialize(allocator),
        }
    }

    pub fn process(self: *MultiplyConjugateBlock, x: []const std.math.Complex(f32), y: []const std.math.Complex(f32), z: []std.math.Complex(f32)) !ProcessResult {
        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| return impl.process(x, y, z),
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Multiply Conjugate Implementation (Volk)
////////////////////////////////////////////////////////////////////////////////

const lv_32fc_t = extern struct {
    real: f32,
    imag: f32,
};
var volk_32fc_x2_multiply_conjugate_32fc: *const *const fn ([*c]lv_32fc_t, [*c]const lv_32fc_t, [*c]const lv_32fc_t, c_uint) callconv(.C) void = undefined;
var volk_loaded: bool = false;

pub const _MultiplyConjugateBlockVolkImpl = struct {
    pub fn initialize(_: *_MultiplyConjugateBlockVolkImpl, _: std.mem.Allocator) !void {
        if (!volk_loaded) {
            volk_32fc_x2_multiply_conjugate_32fc = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_x2_multiply_conjugate_32fc), "volk_32fc_x2_multiply_conjugate_32fc") orelse return error.LookupFail;
            volk_loaded = true;
        }

        if (platform.debug.enabled) std.debug.print("[MultiplyConjugateBlock] Using VOLK implementation\n", .{});
    }

    pub fn deinitialize(_: *_MultiplyConjugateBlockVolkImpl, _: std.mem.Allocator) void {}

    pub fn process(_: *_MultiplyConjugateBlockVolkImpl, x: []const std.math.Complex(f32), y: []const std.math.Complex(f32), z: []std.math.Complex(f32)) !ProcessResult {
        volk_32fc_x2_multiply_conjugate_32fc.*(@ptrCast(z.ptr), @ptrCast(x.ptr), @ptrCast(y.ptr), @intCast(x.len));

        return ProcessResult.init(&[2]usize{ x.len, x.len }, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Multiply Conjguate Implementation (Zig)
////////////////////////////////////////////////////////////////////////////////

pub const _MultiplyConjugateBlockZigImpl = struct {
    pub fn initialize(_: *_MultiplyConjugateBlockZigImpl, _: std.mem.Allocator) !void {
        if (platform.debug.enabled) std.debug.print("[MultiplyConjugateBlock] Using Zig implementation\n", .{});
    }

    pub fn deinitialize(_: *_MultiplyConjugateBlockZigImpl, _: std.mem.Allocator) void {}

    pub fn process(_: *_MultiplyConjugateBlockZigImpl, x: []const std.math.Complex(f32), y: []const std.math.Complex(f32), z: []std.math.Complex(f32)) !ProcessResult {
        for (x, 0..) |_, i| {
            z[i] = x[i].mul(y[i].conjugate());
        }

        return ProcessResult.init(&[2]usize{ x.len, x.len }, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/multiplyconjugate.zig");

test "MultiplyConjugateBlock" {
    {
        var block = MultiplyConjugateBlock.init();
        var tester = try BlockTester(&[2]type{ std.math.Complex(f32), std.math.Complex(f32) }, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{ &vectors.input1_complexfloat32, &vectors.input2_complexfloat32 }, .{&vectors.output_complexfloat32}, .{});
    }
}
