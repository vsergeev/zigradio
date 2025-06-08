const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

////////////////////////////////////////////////////////////////////////////////
// Multiply Block
////////////////////////////////////////////////////////////////////////////////

pub fn MultiplyBlock(comptime T: type) type {
    if (T != std.math.Complex(f32) and T != f32) @compileError("Data type not supported");

    return struct {
        const Self = @This();

        block: Block,
        impl: union(enum) {
            none,
            volk: _MultiplyBlockVolkImpl(T),
            liquid: _MultiplyBlockLiquidImpl(T),
            zig: _MultiplyBlockZigImpl(T),
        } = .none,

        pub fn init() Self {
            return .{ .block = Block.init(@This()) };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            if (platform.libs.volk != null) {
                self.impl = .{ .volk = .{} };
            } else if (platform.libs.liquid != null) {
                self.impl = .{ .liquid = .{} };
            } else {
                self.impl = .{ .zig = .{} };
            }

            switch (self.impl) {
                .none => unreachable,
                inline else => |*impl| try impl.initialize(allocator),
            }
        }

        pub fn deinitialize(self: *Self, allocator: std.mem.Allocator) void {
            switch (self.impl) {
                .none => unreachable,
                inline else => |*impl| impl.deinitialize(allocator),
            }
        }

        pub fn process(self: *Self, x: []const T, y: []const T, z: []T) !ProcessResult {
            switch (self.impl) {
                .none => unreachable,
                inline else => |*impl| return impl.process(x, y, z),
            }
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Multiply Implementation (Volk)
////////////////////////////////////////////////////////////////////////////////

const lv_32fc_t = extern struct {
    real: f32,
    imag: f32,
};
var volk_32fc_x2_multiply_32fc: *const *const fn ([*c]lv_32fc_t, [*c]const lv_32fc_t, [*c]const lv_32fc_t, c_uint) callconv(.C) void = undefined;
var volk_32f_x2_multiply_32f: *const *const fn ([*c]f32, [*c]const f32, [*c]const f32, c_uint) callconv(.C) void = undefined;
var volk_loaded: bool = false;

fn _MultiplyBlockVolkImpl(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn initialize(_: *Self, _: std.mem.Allocator) !void {
            if (!volk_loaded) {
                volk_32fc_x2_multiply_32fc = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_x2_multiply_32fc), "volk_32fc_x2_multiply_32fc") orelse return error.LookupFail;
                volk_32f_x2_multiply_32f = platform.libs.volk.?.lookup(@TypeOf(volk_32f_x2_multiply_32f), "volk_32f_x2_multiply_32f") orelse return error.LookupFail;
                volk_loaded = true;
            }

            if (platform.debug.enabled) std.debug.print("[MultiplyBlock] Using VOLK implementation\n", .{});
        }

        pub fn deinitialize(_: *Self, _: std.mem.Allocator) void {}

        pub fn process(_: *Self, x: []const T, y: []const T, z: []T) !ProcessResult {
            if (T == std.math.Complex(f32)) {
                volk_32fc_x2_multiply_32fc.*(@ptrCast(z.ptr), @ptrCast(x.ptr), @ptrCast(y.ptr), @intCast(x.len));
            } else if (T == f32) {
                volk_32f_x2_multiply_32f.*(@ptrCast(z.ptr), @ptrCast(x.ptr), @ptrCast(y.ptr), @intCast(x.len));
            } else {
                @compileError("Unsupported data type");
            }

            return ProcessResult.init(&[2]usize{ x.len, x.len }, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Multiply Implementation (Liquid)
////////////////////////////////////////////////////////////////////////////////

const liquid_float_complex = extern struct {
    real: f32,
    imag: f32,
};
var liquid_vectorcf_mul: *const fn (_x: [*c]liquid_float_complex, _y: [*c]liquid_float_complex, _n: c_uint, _z: [*c]liquid_float_complex) callconv(.C) void = undefined;
var liquid_vectorf_mul: *const fn (_x: [*c]f32, _y: [*c]f32, _n: c_uint, _z: [*c]f32) callconv(.C) void = undefined;
var liquid_loaded: bool = false;

fn _MultiplyBlockLiquidImpl(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn initialize(_: *Self, _: std.mem.Allocator) !void {
            if (!liquid_loaded) {
                liquid_vectorcf_mul = platform.libs.liquid.?.lookup(@TypeOf(liquid_vectorcf_mul), "liquid_vectorcf_mul") orelse return error.LookupFail;
                liquid_vectorf_mul = platform.libs.liquid.?.lookup(@TypeOf(liquid_vectorf_mul), "liquid_vectorf_mul") orelse return error.LookupFail;
                volk_loaded = true;
            }

            if (platform.debug.enabled) std.debug.print("[MultiplyBlock] Using liquid-dsp implementation\n", .{});
        }

        pub fn deinitialize(_: *Self, _: std.mem.Allocator) void {}

        pub fn process(_: *Self, x: []const T, y: []const T, z: []T) !ProcessResult {
            if (T == std.math.Complex(f32)) {
                liquid_vectorcf_mul(@ptrCast(@constCast(x.ptr)), @ptrCast(@constCast(y.ptr)), @intCast(x.len), @ptrCast(z.ptr));
            } else if (T == f32) {
                liquid_vectorf_mul(@ptrCast(@constCast(x.ptr)), @ptrCast(@constCast(y.ptr)), @intCast(x.len), @ptrCast(z.ptr));
            } else {
                @compileError("Unsupported data type");
            }

            return ProcessResult.init(&[2]usize{ x.len, x.len }, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Multiply Implementation (Zig)
////////////////////////////////////////////////////////////////////////////////

fn _MultiplyBlockZigImpl(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn initialize(_: *Self, _: std.mem.Allocator) !void {
            if (platform.debug.enabled) std.debug.print("[MultiplyBlock] Using Zig implementation\n", .{});
        }

        pub fn deinitialize(_: *Self, _: std.mem.Allocator) void {}

        pub fn process(_: *Self, x: []const T, y: []const T, z: []T) !ProcessResult {
            for (x, 0..) |_, i| {
                if (T == std.math.Complex(f32)) {
                    z[i] = x[i].mul(y[i]);
                } else if (T == f32) {
                    z[i] = x[i] * y[i];
                } else {
                    @compileError("Unsupported data type");
                }
            }

            return ProcessResult.init(&[2]usize{ x.len, x.len }, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/multiply.zig");

test "MultiplyBlock" {
    // Complex
    {
        var block = MultiplyBlock(std.math.Complex(f32)).init();
        var tester = try BlockTester(&[2]type{ std.math.Complex(f32), std.math.Complex(f32) }, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{ &vectors.input1_complexfloat32, &vectors.input2_complexfloat32 }, .{&vectors.output_complexfloat32}, .{});
    }

    // Real
    {
        var block = MultiplyBlock(f32).init();
        var tester = try BlockTester(&[2]type{ f32, f32 }, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{ &vectors.input1_float32, &vectors.input2_float32 }, .{&vectors.output_float32}, .{});
    }
}
