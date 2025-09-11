// @block ComplexToRealBlock
// @description Decompose the real part of a complex-valued signal.
//
// $$ y[n] = \text{Re}(x[n]) $$
//
// @category Type Conversion
// @signature in:Complex(f32) > out:f32
// @usage
// var complextoreal = radio.blocks.ComplexToRealBlock.init();

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

////////////////////////////////////////////////////////////////////////////////
// Complex to Real Block
////////////////////////////////////////////////////////////////////////////////

pub const ComplexToRealBlock = struct {
    block: Block,
    impl: union(enum) {
        none,
        volk: _ComplexToRealBlockVolkImpl,
        zig: _ComplexToRealBlockZigImpl,
    } = .none,

    pub fn init() ComplexToRealBlock {
        return .{ .block = Block.init(@This()) };
    }

    pub fn initialize(self: *ComplexToRealBlock, allocator: std.mem.Allocator) !void {
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

    pub fn deinitialize(self: *ComplexToRealBlock, allocator: std.mem.Allocator) void {
        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| impl.deinitialize(allocator),
        }
    }

    pub fn process(self: *ComplexToRealBlock, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| return impl.process(x, z),
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Complex to Real Implementation (Volk)
////////////////////////////////////////////////////////////////////////////////

const lv_32fc_t = extern struct {
    real: f32,
    imag: f32,
};
var volk_32fc_deinterleave_real_32f: *const *const fn ([*c]f32, [*c]const lv_32fc_t, c_uint) callconv(.c) void = undefined;
var volk_loaded: bool = false;

pub const _ComplexToRealBlockVolkImpl = struct {
    parent: *const ComplexToRealBlock,

    pub fn initialize(_: *_ComplexToRealBlockVolkImpl, _: std.mem.Allocator) !void {
        if (!volk_loaded) {
            volk_32fc_deinterleave_real_32f = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_deinterleave_real_32f), "volk_32fc_deinterleave_real_32f") orelse return error.LookupFail;
            volk_loaded = true;
        }

        if (platform.debug.enabled) std.debug.print("[ComplexToRealBlock] Using VOLK implementation\n", .{});
    }

    pub fn deinitialize(_: *_ComplexToRealBlockVolkImpl, _: std.mem.Allocator) void {}

    pub fn process(_: *_ComplexToRealBlockVolkImpl, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        volk_32fc_deinterleave_real_32f.*(z.ptr, @ptrCast(x.ptr), @intCast(x.len));

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Complex to Real Implementation (Zig)
////////////////////////////////////////////////////////////////////////////////

pub const _ComplexToRealBlockZigImpl = struct {
    parent: *const ComplexToRealBlock,

    pub fn initialize(_: *_ComplexToRealBlockZigImpl, _: std.mem.Allocator) !void {
        if (platform.debug.enabled) std.debug.print("[ComplexToRealBlock] Using Zig implementation\n", .{});
    }

    pub fn deinitialize(_: *_ComplexToRealBlockZigImpl, _: std.mem.Allocator) void {}

    pub fn process(_: *_ComplexToRealBlockZigImpl, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        for (x, 0..) |_, i| z[i] = x[i].re;

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/complextoreal.zig");

test "ComplexToRealBlock" {
    {
        var block = ComplexToRealBlock.init();
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{f32}).init(&block.block, 1e-5);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_real}, .{});
    }
}
