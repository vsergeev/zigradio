// @block IIRFilterBlock
// @description Filter a complex or real valued signal with an IIR filter.
//
// $$ y[n] = (x * h)[n] $$
//
// $$ \begin{align} y[n] = &\frac{1}{a_0}(b_0 x[n] + b_1 x[n-1] + ... + b_N x[n-N] \\ - &a_1 y[n-1] - a_2 y[n-2] - ... - a_M x[n-M])\end{align} $$
//
// @category Filtering
// @ctparam T type Complex(f32), f32
// @ctparam N comptime_int Number of feedforward taps
// @ctparam M comptime_int Number of feedback taps
// @param b_taps [N]f32 Feedforward taps
// @param a_taps [M]f32 Feedback taps
// @signature in:T > out:T
// @usage
// var filter = radio.blocks.IIRFilterBlock(std.math.Complex(f32), 3, 3).init(b_taps, a_taps);

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

const zero = @import("../../radio.zig").utils.math.zero;
const sub = @import("../../radio.zig").utils.math.sub;
const scalarDiv = @import("../../radio.zig").utils.math.scalarDiv;
const innerProduct = @import("../../radio.zig").utils.math.innerProduct;

////////////////////////////////////////////////////////////////////////////////
// IIR Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn IIRFilterBlock(comptime T: type, comptime N: comptime_int, comptime M: comptime_int) type {
    return struct {
        const Self = @This();

        block: Block,
        filter: IIRFilter(T, N, M),

        pub fn init(b_taps: [N]f32, a_taps: [M]f32) Self {
            var filter = IIRFilter(T, N, M).init();
            @memcpy(&filter.b_taps, &b_taps);
            @memcpy(&filter.a_taps, &a_taps);
            return .{ .block = Block.init(@This()), .filter = filter };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            return self.filter.initialize(allocator);
        }

        pub fn deinitialize(self: *Self, allocator: std.mem.Allocator) void {
            return self.filter.deinitialize(allocator);
        }

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            return self.filter.process(x, y);
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// IIR Filter (Standalone)
////////////////////////////////////////////////////////////////////////////////

pub fn IIRFilter(comptime T: type, comptime N: comptime_int, comptime M: comptime_int) type {
    if (T != std.math.Complex(f32) and T != f32) @compileError("Only std.math.Complex(f32) and f32 data types supported");
    if (M < 1) @compileError("Feedback taps length must be at least 1");

    return struct {
        const Self = @This();

        b_taps: [N]f32 = [_]f32{0} ** N,
        a_taps: [M]f32 = [_]f32{0} ** M,
        impl: union(enum) {
            none,
            volk: _IIRFilterBlockVolkImpl(T, N, M, Self),
            liquid: _IIRFilterBlockLiquidImpl(T, N, M, Self),
            zig: _IIRFilterBlockZigImpl(T, N, M, Self),
        } = .none,

        pub fn init() Self {
            return .{};
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            // Prefer pure Zig implementation for now (benchmarks better)
            self.impl = .{ .zig = _IIRFilterBlockZigImpl(T, N, M, Self){ .parent = self } };

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

////////////////////////////////////////////////////////////////////////////////
// IIR Filter Implementation (Volk)
////////////////////////////////////////////////////////////////////////////////

const lv_32fc_t = extern struct {
    real: f32,
    imag: f32,
};
var volk_32fc_32f_dot_prod_32fc: *const *const fn (*lv_32fc_t, [*c]const lv_32fc_t, [*c]const f32, c_uint) callconv(.C) void = undefined;
var volk_32f_x2_dot_prod_32f: *const *const fn (*f32, [*c]const f32, [*c]const f32, c_uint) callconv(.C) void = undefined;
var volk_loaded: bool = false;

fn _IIRFilterBlockVolkImpl(comptime T: type, comptime N: comptime_int, comptime M: comptime_int, comptime Parent: type) type {
    return struct {
        const Self = @This();
        const Alignment = 32;

        parent: *const Parent,
        b_taps: std.ArrayListAligned(f32, Alignment) = undefined,
        a_taps: std.ArrayListAligned(f32, Alignment) = undefined,
        input_state: std.ArrayList(T) = undefined,
        output_state: std.ArrayList(T) = undefined,

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            if (!volk_loaded) {
                volk_32fc_32f_dot_prod_32fc = platform.libs.volk.?.lookup(@TypeOf(volk_32fc_32f_dot_prod_32fc), "volk_32fc_32f_dot_prod_32fc") orelse return error.LookupFail;
                volk_32f_x2_dot_prod_32f = platform.libs.volk.?.lookup(@TypeOf(volk_32f_x2_dot_prod_32f), "volk_32f_x2_dot_prod_32f") orelse return error.LookupFail;
                volk_loaded = true;
            }

            // Copy b taps (backwards)
            self.b_taps = std.ArrayListAligned(f32, Alignment).init(allocator);
            try self.b_taps.resize(N);
            for (0..N) |i| self.b_taps.items[i] = self.parent.b_taps[N - 1 - i];

            // Copy a taps (forwards)
            self.a_taps = std.ArrayListAligned(f32, Alignment).init(allocator);
            try self.a_taps.appendSlice(self.parent.a_taps[0..M]);

            // Initialize state
            self.input_state = std.ArrayList(T).init(allocator);
            self.output_state = std.ArrayList(T).init(allocator);
            try self.input_state.appendNTimes(zero(T), N);
            try self.output_state.appendNTimes(zero(T), M - 1);

            if (platform.debug.enabled) std.debug.print("[IIRFilterBlock] Using VOLK implementation\n", .{});
        }

        pub fn deinitialize(self: *Self, _: std.mem.Allocator) void {
            self.output_state.deinit();
            self.input_state.deinit();
            self.a_taps.deinit();
            self.b_taps.deinit();
        }

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            // Shift last b_taps_length-1 state samples to the beginning of state
            for (self.input_state.items.len - (N - 1)..self.input_state.items.len, 0..) |src, dst| self.input_state.items[dst] = self.input_state.items[src];
            // Adjust state vector length for the input
            try self.input_state.resize(N - 1 + x.len);
            // Copy input into state
            @memcpy(self.input_state.items[N - 1 ..], x);

            for (x, 0..) |_, i| {
                var feedforward: T = undefined;
                var feedback: T = undefined;

                // Inner product of b taps and input state
                if (T == std.math.Complex(f32)) {
                    volk_32fc_32f_dot_prod_32fc.*(@ptrCast(&feedforward), @ptrCast(self.input_state.items[i .. i + N]), @ptrCast(self.b_taps.items.ptr), N);
                } else if (T == f32) {
                    volk_32f_x2_dot_prod_32f.*(&feedforward, self.input_state.items[i .. i + N].ptr, self.b_taps.items.ptr, N);
                }

                // Inner product of a taps and output state
                if (T == std.math.Complex(f32)) {
                    volk_32fc_32f_dot_prod_32fc.*(@ptrCast(&feedback), @ptrCast(self.output_state.items.ptr), @ptrCast(self.a_taps.items[1..].ptr), M);
                } else if (T == f32) {
                    volk_32f_x2_dot_prod_32f.*(&feedback, self.output_state.items.ptr, self.a_taps.items[1..].ptr, M);
                }

                y[i] = scalarDiv(T, sub(T, feedforward, feedback), self.a_taps.items[0]);

                // Shift the output state samples down
                for (0..M - 2) |j| self.output_state.items[M - 2 - j] = self.output_state.items[M - 3 - j];
                // Insert output sample into output state
                self.output_state.items[0] = y[i];
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// IIR Filter Implementation (Liquid)
////////////////////////////////////////////////////////////////////////////////

const liquid_float_complex = extern struct {
    real: f32,
    imag: f32,
};

const struct_iirfilt_crcf_s = opaque {};
const iirfilt_crcf = ?*struct_iirfilt_crcf_s;
var iirfilt_crcf_create: *const fn (_b: [*c]f32, _nb: c_uint, _a: [*c]f32, _na: c_uint) callconv(.C) iirfilt_crcf = undefined;
var iirfilt_crcf_destroy: *const fn (_q: iirfilt_crcf) callconv(.C) c_int = undefined;
var iirfilt_crcf_execute_block: *const fn (_q: iirfilt_crcf, _x: [*c]liquid_float_complex, _n: c_uint, _y: [*c]liquid_float_complex) callconv(.C) c_int = undefined;

const struct_iirfilt_rrrf_s = opaque {};
const iirfilt_rrrf = ?*struct_iirfilt_rrrf_s;
var iirfilt_rrrf_create: *const fn (_b: [*c]f32, _nb: c_uint, _a: [*c]f32, _na: c_uint) callconv(.C) iirfilt_rrrf = undefined;
var iirfilt_rrrf_destroy: *const fn (_q: iirfilt_rrrf) callconv(.C) c_int = undefined;
var iirfilt_rrrf_execute_block: *const fn (_q: iirfilt_rrrf, _x: [*c]f32, _n: c_uint, _y: [*c]f32) callconv(.C) c_int = undefined;

var liquid_loaded: bool = false;

fn _IIRFilterBlockLiquidImpl(comptime T: type, comptime N: comptime_int, comptime M: comptime_int, comptime Parent: type) type {
    return struct {
        const Self = @This();

        parent: *const Parent,
        filter: if (T == std.math.Complex(f32)) iirfilt_crcf else if (T == f32) iirfilt_rrrf = undefined,

        pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
            if (!liquid_loaded) {
                iirfilt_crcf_create = platform.libs.liquid.?.lookup(@TypeOf(iirfilt_crcf_create), "iirfilt_crcf_create") orelse return error.LookupFail;
                iirfilt_crcf_destroy = platform.libs.liquid.?.lookup(@TypeOf(iirfilt_crcf_destroy), "iirfilt_crcf_destroy") orelse return error.LookupFail;
                iirfilt_crcf_execute_block = platform.libs.liquid.?.lookup(@TypeOf(iirfilt_crcf_execute_block), "iirfilt_crcf_execute_block") orelse return error.LookupFail;
                iirfilt_rrrf_create = platform.libs.liquid.?.lookup(@TypeOf(iirfilt_rrrf_create), "iirfilt_rrrf_create") orelse return error.LookupFail;
                iirfilt_rrrf_destroy = platform.libs.liquid.?.lookup(@TypeOf(iirfilt_rrrf_destroy), "iirfilt_rrrf_destroy") orelse return error.LookupFail;
                iirfilt_rrrf_execute_block = platform.libs.liquid.?.lookup(@TypeOf(iirfilt_rrrf_execute_block), "iirfilt_rrrf_execute_block") orelse return error.LookupFail;
                liquid_loaded = true;
            }

            if (T == std.math.Complex(f32)) {
                self.filter = iirfilt_crcf_create(@constCast(self.parent.b_taps[0..]), N, @constCast(self.parent.a_taps[0..]), M);
            } else if (T == f32) {
                self.filter = iirfilt_rrrf_create(@constCast(self.parent.b_taps[0..]), N, @constCast(self.parent.a_taps[0..]), M);
            }

            if (self.filter == null) return error.OutOfMemory;

            if (platform.debug.enabled) std.debug.print("[IIRFilterBlock] Using liquid-dsp implementation\n", .{});
        }

        pub fn deinitialize(self: *Self, _: std.mem.Allocator) void {
            if (T == std.math.Complex(f32)) {
                _ = iirfilt_crcf_destroy(self.filter);
            } else if (T == f32) {
                _ = iirfilt_rrrf_destroy(self.filter);
            }
        }

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            if (T == std.math.Complex(f32)) {
                _ = iirfilt_crcf_execute_block(self.filter, @ptrCast(@constCast(x.ptr)), @intCast(x.len), @ptrCast(y.ptr));
            } else if (T == f32) {
                _ = iirfilt_rrrf_execute_block(self.filter, @ptrCast(@constCast(x.ptr)), @intCast(x.len), @ptrCast(y.ptr));
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// IIR Filter Implementation (Zig)
////////////////////////////////////////////////////////////////////////////////

fn _IIRFilterBlockZigImpl(comptime T: type, comptime N: comptime_int, comptime M: comptime_int, comptime Parent: type) type {
    return struct {
        const Self = @This();

        parent: *const Parent,
        input_state: [N]T = [_]T{zero(T)} ** N,
        output_state: [M - 1]T = [_]T{zero(T)} ** (M - 1),

        pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
            for (&self.input_state) |*e| e.* = zero(T);
            for (&self.output_state) |*e| e.* = zero(T);

            if (platform.debug.enabled) std.debug.print("[IIRFilterBlock] Using Zig implementation\n", .{});
        }

        pub fn deinitialize(_: *Self, _: std.mem.Allocator) void {}

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            for (x, 0..) |_, i| {
                // Shift the input state samples down
                for (0..N - 1) |j| self.input_state[N - 1 - j] = self.input_state[N - 2 - j];
                // Insert input sample into input state
                self.input_state[0] = x[i];

                // y[n] = (b[0]*x[n] + b[1]*x[n-1] + b[2]*x[n-2] + ...  - a[1]*y[n-1] - a[2]*y[n-2] - ...) / a[0]
                y[i] = scalarDiv(T, sub(T, innerProduct(T, f32, &self.input_state, &self.parent.b_taps), innerProduct(T, f32, &self.output_state, self.parent.a_taps[1..])), self.parent.a_taps[0]);

                // Shift the output state samples down
                for (0..M - 2) |j| self.output_state[M - 2 - j] = self.output_state[M - 3 - j];
                // Insert output sample into output state
                self.output_state[0] = y[i];
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/iirfilter.zig");

test "IIRFilterBlock" {
    // 3 feedforward taps, 3 feedback taps, ComplexFloat32
    {
        var block = IIRFilterBlock(std.math.Complex(f32), 3, 3).init(vectors.input_taps_3_b, vectors.input_taps_3_a);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_3_3_complexfloat32}, .{});
    }

    // 5 feedforward taps, 5 feedback taps, ComplexFloat32
    {
        var block = IIRFilterBlock(std.math.Complex(f32), 5, 5).init(vectors.input_taps_5_b, vectors.input_taps_5_a);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_5_5_complexfloat32}, .{});
    }

    // 3 feedforward taps, 3 feedback taps, Float32
    {
        var block = IIRFilterBlock(f32, 3, 3).init(vectors.input_taps_3_b, vectors.input_taps_3_a);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_taps_3_3_float32}, .{});
    }

    // 5 feedforward taps, 5 feedback taps, Float32
    {
        var block = IIRFilterBlock(f32, 5, 5).init(vectors.input_taps_5_b, vectors.input_taps_5_a);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_taps_5_5_float32}, .{});
    }
}
