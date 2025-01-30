const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

const zero = @import("../../radio.zig").utils.math.zero;
const innerProduct = @import("../../radio.zig").utils.math.innerProduct;

////////////////////////////////////////////////////////////////////////////////
// FIR Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn _FIRFilterBlock(comptime T: type, comptime U: type, comptime N: comptime_int, comptime Context: type) type {
    if (!((T == std.math.Complex(f32) and U == std.math.Complex(f32)) or
        (T == std.math.Complex(f32) and U == f32) or
        (T == f32 and U == f32))) @compileError("Data types combination not supported");

    return struct {
        const Self = @This();

        block: Block,
        context: Context,
        taps: [N]U = [_]U{zero(U)} ** N,
        impl: union(enum) {
            none,
            volk: _FIRFilterBlockVolkImpl(T, U, N, Self),
            liquid: _FIRFilterBlockLiquidImpl(T, U, N, Self),
            zig: _FIRFilterBlockZigImpl(T, U, N, Self),
        } = .none,

        pub const init = Context.init;

        pub fn _init(context: Context) Self {
            return .{ .block = Block.init(@This()), .context = context };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            if (@hasDecl(Context, "initialize")) {
                try Context.initialize(self, allocator);
            }

            if (platform.libs.volk != null) {
                self.impl = .{ .volk = _FIRFilterBlockVolkImpl(T, U, N, Self){ .parent = self } };
            } else if (platform.libs.liquid != null) {
                self.impl = .{ .liquid = _FIRFilterBlockLiquidImpl(T, U, N, Self){ .parent = self } };
            } else {
                self.impl = .{ .zig = _FIRFilterBlockZigImpl(T, U, N, Self){ .parent = self } };
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

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            switch (self.impl) {
                .none => unreachable,
                inline else => |*impl| return impl.process(x, y),
            }
        }
    };
}

pub fn FIRFilterBlock(comptime T: type, comptime U: type, comptime N: comptime_int) type {
    return _FIRFilterBlock(T, U, N, struct {
        pub fn init(taps: [N]U) FIRFilterBlock(T, U, N) {
            var block = FIRFilterBlock(T, U, N)._init(.{});
            @memcpy(&block.taps, &taps);
            return block;
        }
    });
}

////////////////////////////////////////////////////////////////////////////////
// FIR Filter Implementation (Volk)
////////////////////////////////////////////////////////////////////////////////

const lv_32fc_t = extern struct {
    real: f32,
    imag: f32,
};
var volk_32fc_x2_dot_prod_32fc: *const *const fn (*lv_32fc_t, [*c]const lv_32fc_t, [*c]const lv_32fc_t, c_uint) callconv(.C) void = undefined;
var volk_32fc_32f_dot_prod_32fc: *const *const fn (*lv_32fc_t, [*c]const lv_32fc_t, [*c]const f32, c_uint) callconv(.C) void = undefined;
var volk_32f_x2_dot_prod_32f: *const *const fn (*f32, [*c]const f32, [*c]const f32, c_uint) callconv(.C) void = undefined;
var volk_loaded: bool = false;

fn _FIRFilterBlockVolkImpl(comptime T: type, comptime U: type, comptime N: comptime_int, comptime Parent: type) type {
    return struct {
        const Self = @This();
        const Alignment = 32;

        parent: *const Parent,
        taps: std.ArrayListAligned(U, Alignment) = undefined,
        state: std.ArrayList(T) = undefined,

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            if (!volk_loaded) {
                volk_32fc_x2_dot_prod_32fc = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_x2_dot_prod_32fc), "volk_32fc_x2_dot_prod_32fc") orelse return error.LookupFail;
                volk_32fc_32f_dot_prod_32fc = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_32f_dot_prod_32fc), "volk_32fc_32f_dot_prod_32fc") orelse return error.LookupFail;
                volk_32f_x2_dot_prod_32f = platform.libs.volk.?.lookup(@TypeOf(volk_32f_x2_dot_prod_32f), "volk_32f_x2_dot_prod_32f") orelse return error.LookupFail;
                volk_loaded = true;
            }

            // Copy taps (backwards)
            self.taps = std.ArrayListAligned(U, Alignment).init(allocator);
            try self.taps.resize(N);
            for (0..N) |i| self.taps.items[i] = self.parent.taps[N - 1 - i];

            // Initialize state
            self.state = std.ArrayList(T).init(allocator);
            try self.state.appendNTimes(zero(T), N);

            if (platform.debug.enabled) std.debug.print("[FIRFilterBlock] Using VOLK implementation\n", .{});
        }

        pub fn deinitialize(self: *Self, _: std.mem.Allocator) void {
            self.state.deinit();
            self.taps.deinit();
        }

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            // Shift last taps_length-1 state samples to the beginning of state
            for (self.state.items.len - (N - 1)..self.state.items.len, 0..) |src, dst| self.state.items[dst] = self.state.items[src];
            // Adjust state vector length for the input
            try self.state.resize(N - 1 + x.len);
            // Copy input into state
            @memcpy(self.state.items[N - 1 ..], x);

            // Inner product
            if (T == std.math.Complex(f32) and U == std.math.Complex(f32)) {
                for (0..x.len) |i| volk_32fc_x2_dot_prod_32fc.*(@ptrCast(&y[i]), @ptrCast(self.state.items[i .. i + N]), @ptrCast(self.taps.items.ptr), N);
            } else if (T == std.math.Complex(f32) and U == f32) {
                for (0..x.len) |i| volk_32fc_32f_dot_prod_32fc.*(@ptrCast(&y[i]), @ptrCast(self.state.items[i .. i + N]), self.taps.items.ptr, N);
            } else if (T == f32 and U == f32) {
                for (0..x.len) |i| volk_32f_x2_dot_prod_32f.*(&y[i], @ptrCast(self.state.items[i .. i + N]), self.taps.items.ptr, N);
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// FIR Filter Implementation (Liquid)
////////////////////////////////////////////////////////////////////////////////

const liquid_float_complex = extern struct {
    real: f32,
    imag: f32,
};

const struct_firfilt_cccf_s = opaque {};
const firfilt_cccf = ?*struct_firfilt_cccf_s;
var firfilt_cccf_create: *const fn (_h: [*c]liquid_float_complex, _n: c_uint) firfilt_cccf = undefined;
var firfilt_cccf_destroy: *const fn (_q: firfilt_cccf) c_int = undefined;
var firfilt_cccf_execute_block: *const fn (_q: firfilt_cccf, _x: [*c]liquid_float_complex, _n: c_uint, _y: [*c]liquid_float_complex) c_int = undefined;

const struct_firfilt_crcf_s = opaque {};
const firfilt_crcf = ?*struct_firfilt_crcf_s;
var firfilt_crcf_create: *const fn (_h: [*c]f32, _n: c_uint) firfilt_crcf = undefined;
var firfilt_crcf_destroy: *const fn (_q: firfilt_crcf) c_int = undefined;
var firfilt_crcf_execute_block: *const fn (_q: firfilt_crcf, _x: [*c]liquid_float_complex, _n: c_uint, _y: [*c]liquid_float_complex) c_int = undefined;

const struct_firfilt_rrrf_s = opaque {};
const firfilt_rrrf = ?*struct_firfilt_rrrf_s;
var firfilt_rrrf_create: *const fn (_h: [*c]f32, _n: c_uint) firfilt_rrrf = undefined;
var firfilt_rrrf_destroy: *const fn (_q: firfilt_rrrf) c_int = undefined;
var firfilt_rrrf_execute_block: *const fn (_q: firfilt_rrrf, _x: [*c]f32, _n: c_uint, _y: [*c]f32) c_int = undefined;

var liquid_loaded: bool = false;

fn _FIRFilterBlockLiquidImpl(comptime T: type, comptime U: type, comptime N: comptime_int, comptime Parent: type) type {
    return struct {
        const Self = @This();

        parent: *const Parent,
        filter: if (T == std.math.Complex(f32) and U == std.math.Complex(f32)) firfilt_cccf else if (T == std.math.Complex(f32) and U == f32) firfilt_crcf else if (T == f32 and U == f32) firfilt_rrrf = undefined,

        pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
            if (!liquid_loaded) {
                firfilt_cccf_create = platform.libs.liquid.?.lookup(@TypeOf(firfilt_cccf_create), "firfilt_cccf_create") orelse return error.LookupFail;
                firfilt_cccf_destroy = platform.libs.liquid.?.lookup(@TypeOf(firfilt_cccf_destroy), "firfilt_cccf_destroy") orelse return error.LookupFail;
                firfilt_cccf_execute_block = platform.libs.liquid.?.lookup(@TypeOf(firfilt_cccf_execute_block), "firfilt_cccf_execute_block") orelse return error.LookupFail;
                firfilt_crcf_create = platform.libs.liquid.?.lookup(@TypeOf(firfilt_crcf_create), "firfilt_crcf_create") orelse return error.LookupFail;
                firfilt_crcf_destroy = platform.libs.liquid.?.lookup(@TypeOf(firfilt_crcf_destroy), "firfilt_crcf_destroy") orelse return error.LookupFail;
                firfilt_crcf_execute_block = platform.libs.liquid.?.lookup(@TypeOf(firfilt_crcf_execute_block), "firfilt_crcf_execute_block") orelse return error.LookupFail;
                firfilt_rrrf_create = platform.libs.liquid.?.lookup(@TypeOf(firfilt_rrrf_create), "firfilt_rrrf_create") orelse return error.LookupFail;
                firfilt_rrrf_destroy = platform.libs.liquid.?.lookup(@TypeOf(firfilt_rrrf_destroy), "firfilt_rrrf_destroy") orelse return error.LookupFail;
                firfilt_rrrf_execute_block = platform.libs.liquid.?.lookup(@TypeOf(firfilt_rrrf_execute_block), "firfilt_rrrf_execute_block") orelse return error.LookupFail;
                liquid_loaded = true;
            }

            if (T == std.math.Complex(f32) and U == std.math.Complex(f32)) {
                self.filter = firfilt_cccf_create(@ptrCast(@constCast(self.parent.taps[0..])), N);
            } else if (T == std.math.Complex(f32) and U == f32) {
                self.filter = firfilt_crcf_create(@constCast(self.parent.taps[0..]), N);
            } else if (T == f32 and U == f32) {
                self.filter = firfilt_rrrf_create(@constCast(self.parent.taps[0..]), N);
            }

            if (self.filter == null) return error.OutOfMemory;

            if (platform.debug.enabled) std.debug.print("[FIRFilterBlock] Using liquid-dsp implementation\n", .{});
        }

        pub fn deinitialize(self: *Self, _: std.mem.Allocator) void {
            if (T == std.math.Complex(f32) and U == std.math.Complex(f32)) {
                _ = firfilt_cccf_destroy(self.filter);
            } else if (T == std.math.Complex(f32) and U == f32) {
                _ = firfilt_crcf_destroy(self.filter);
            } else if (T == f32 and U == f32) {
                _ = firfilt_rrrf_destroy(self.filter);
            }
        }

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            if (T == std.math.Complex(f32) and U == std.math.Complex(f32)) {
                _ = firfilt_cccf_execute_block(self.filter, @ptrCast(@constCast(x.ptr)), @intCast(x.len), @ptrCast(y.ptr));
            } else if (T == std.math.Complex(f32) and U == f32) {
                _ = firfilt_crcf_execute_block(self.filter, @ptrCast(@constCast(x.ptr)), @intCast(x.len), @ptrCast(y.ptr));
            } else if (T == f32 and U == f32) {
                _ = firfilt_rrrf_execute_block(self.filter, @constCast(x.ptr), @intCast(x.len), y.ptr);
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// FIR Filter Implementation (Zig)
////////////////////////////////////////////////////////////////////////////////

fn _FIRFilterBlockZigImpl(comptime T: type, comptime U: type, comptime N: comptime_int, comptime Parent: type) type {
    return struct {
        const Self = @This();

        parent: *const Parent,
        state: [N]T = [_]T{zero(T)} ** N,

        pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
            for (&self.state) |*e| e.* = zero(T);

            if (platform.debug.enabled) std.debug.print("[FIRFilterBlock] Using Zig implementation\n", .{});
        }

        pub fn deinitialize(_: *Self, _: std.mem.Allocator) void {}

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            for (x, 0..) |_, i| {
                // Shift the input state samples down
                for (0..N - 1) |j| self.state[N - 1 - j] = self.state[N - 2 - j];
                // Insert input sample into input state
                self.state[0] = x[i];

                // y[n] = b[0]*x[n] + b[1]*x[n-1] + b[2]*x[n-2] + ...
                y[i] = innerProduct(T, U, &self.state, &self.parent.taps);
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/firfilter.zig");

test "FIRFilterBlock" {
    // 1 real tap, ComplexFloat32
    {
        var block = FIRFilterBlock(std.math.Complex(f32), f32, 1).init(vectors.input_taps_1);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_1_complexfloat32});
    }

    // 8 real taps, ComplexFloat32
    {
        var block = FIRFilterBlock(std.math.Complex(f32), f32, 8).init(vectors.input_taps_8);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_8_complexfloat32});
    }

    // 1 real tap, Float32
    {
        var block = FIRFilterBlock(f32, f32, 1).init(vectors.input_taps_1);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_taps_1_float32});
    }

    // 8 real taps, Float32
    {
        var block = FIRFilterBlock(f32, f32, 8).init(vectors.input_taps_8);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_taps_8_float32});
    }

    // 1 complex tap, ComplexFloat32
    {
        var block = FIRFilterBlock(std.math.Complex(f32), std.math.Complex(f32), 1).init(vectors.input_complex_taps_1);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_complex_taps_1_complexfloat32});
    }

    // 8 complex tap, ComplexFloat32
    {
        var block = FIRFilterBlock(std.math.Complex(f32), std.math.Complex(f32), 8).init(vectors.input_complex_taps_8);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_complex_taps_8_complexfloat32});
    }
}
