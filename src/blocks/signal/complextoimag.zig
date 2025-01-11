const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

////////////////////////////////////////////////////////////////////////////////
// Complex to Imag Block
////////////////////////////////////////////////////////////////////////////////

pub const ComplexToImagBlock = struct {
    block: Block,
    impl: union(enum) {
        none,
        volk: _ComplexToImagBlockVolkImpl,
        zig: _ComplexToImagBlockZigImpl,
    } = .none,

    pub fn init() ComplexToImagBlock {
        return .{ .block = Block.init(@This()) };
    }

    pub fn initialize(self: *ComplexToImagBlock, allocator: std.mem.Allocator) !void {
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

    pub fn deinitialize(self: *ComplexToImagBlock, allocator: std.mem.Allocator) void {
        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| impl.deinitialize(allocator),
        }
    }

    pub fn process(self: *ComplexToImagBlock, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| return impl.process(x, z),
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Complex to Imag Implementation (Volk)
////////////////////////////////////////////////////////////////////////////////

const lv_32fc_t = extern struct {
    real: f32,
    imag: f32,
};
var volk_32fc_deinterleave_imag_32f: *const *const fn ([*c]f32, [*c]const lv_32fc_t, c_uint) callconv(.C) void = undefined;
var volk_loaded: bool = false;

pub const _ComplexToImagBlockVolkImpl = struct {
    parent: *const ComplexToImagBlock,

    pub fn initialize(_: *_ComplexToImagBlockVolkImpl, _: std.mem.Allocator) !void {
        if (!volk_loaded) {
            volk_32fc_deinterleave_imag_32f = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_deinterleave_imag_32f), "volk_32fc_deinterleave_imag_32f") orelse return error.LookupFail;
            volk_loaded = true;
        }

        if (platform.debug.enabled) std.debug.print("[ComplexToImagBlock] Using VOLK implementation\n", .{});
    }

    pub fn deinitialize(_: *_ComplexToImagBlockVolkImpl, _: std.mem.Allocator) void {}

    pub fn process(_: *_ComplexToImagBlockVolkImpl, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        volk_32fc_deinterleave_imag_32f.*(z.ptr, @ptrCast(x.ptr), @intCast(x.len));

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Complex to Imag Implementation (Zig)
////////////////////////////////////////////////////////////////////////////////

pub const _ComplexToImagBlockZigImpl = struct {
    parent: *const ComplexToImagBlock,

    pub fn initialize(_: *_ComplexToImagBlockZigImpl, _: std.mem.Allocator) !void {
        if (platform.debug.enabled) std.debug.print("[ComplexToImagBlock] Using Zig implementation\n", .{});
    }

    pub fn deinitialize(_: *_ComplexToImagBlockZigImpl, _: std.mem.Allocator) void {}

    pub fn process(_: *_ComplexToImagBlockZigImpl, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        for (x, 0..) |_, i| z[i] = x[i].im;

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/complextoimag.zig");

test "ComplexToImagBlock" {
    {
        var block = ComplexToImagBlock.init();
        var tester = BlockTester.init(&block.block, 1e-5);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{f32}, .{&vectors.output_imag});
    }
}
