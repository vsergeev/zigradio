const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

////////////////////////////////////////////////////////////////////////////////
// Complex Magnitude Block
////////////////////////////////////////////////////////////////////////////////

pub const ComplexMagnitudeBlock = struct {
    block: Block,
    impl: union(enum) {
        none,
        volk: _ComplexMagnitudeBlockVolkImpl,
        zig: _ComplexMagnitudeBlockZigImpl,
    } = .none,

    pub fn init() ComplexMagnitudeBlock {
        return .{ .block = Block.init(@This()) };
    }

    pub fn initialize(self: *ComplexMagnitudeBlock, allocator: std.mem.Allocator) !void {
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

    pub fn deinitialize(self: *ComplexMagnitudeBlock, allocator: std.mem.Allocator) void {
        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| impl.deinitialize(allocator),
        }
    }

    pub fn process(self: *ComplexMagnitudeBlock, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        switch (self.impl) {
            .none => unreachable,
            inline else => |*impl| return impl.process(x, z),
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Complex Magnitude Implementation (Volk)
////////////////////////////////////////////////////////////////////////////////

const lv_32fc_t = extern struct {
    real: f32,
    imag: f32,
};
var volk_32fc_magnitude_32f: *const *const fn ([*c]f32, [*c]const lv_32fc_t, c_uint) callconv(.C) void = undefined;
var volk_loaded: bool = false;

pub const _ComplexMagnitudeBlockVolkImpl = struct {
    parent: *const ComplexMagnitudeBlock,

    pub fn initialize(_: *_ComplexMagnitudeBlockVolkImpl, _: std.mem.Allocator) !void {
        if (!volk_loaded) {
            volk_32fc_magnitude_32f = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_magnitude_32f), "volk_32fc_magnitude_32f") orelse return error.LookupFail;
            volk_loaded = true;
        }

        if (platform.debug.enabled) std.debug.print("[ComplexMagnitudeBlock] Using VOLK implementation\n", .{});
    }

    pub fn deinitialize(_: *_ComplexMagnitudeBlockVolkImpl, _: std.mem.Allocator) void {}

    pub fn process(_: *_ComplexMagnitudeBlockVolkImpl, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        volk_32fc_magnitude_32f.*(z.ptr, @ptrCast(x.ptr), @intCast(x.len));

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Complex Magnitude Implementation (Zig)
////////////////////////////////////////////////////////////////////////////////

pub const _ComplexMagnitudeBlockZigImpl = struct {
    parent: *const ComplexMagnitudeBlock,

    pub fn initialize(_: *_ComplexMagnitudeBlockZigImpl, _: std.mem.Allocator) !void {
        if (platform.debug.enabled) std.debug.print("[ComplexMagnitudeBlock] Using Zig implementation\n", .{});
    }

    pub fn deinitialize(_: *_ComplexMagnitudeBlockZigImpl, _: std.mem.Allocator) void {}

    pub fn process(_: *_ComplexMagnitudeBlockZigImpl, x: []const std.math.Complex(f32), z: []f32) !ProcessResult {
        for (x, 0..) |_, i| z[i] = x[i].magnitude();

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/complexmagnitude.zig");

test "ComplexMagnitudeBlock" {
    {
        var block = ComplexMagnitudeBlock.init();
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{f32}).init(&block.block, 1e-5);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_magnitude}, .{});
    }
}
