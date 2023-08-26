const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const zero = @import("../../radio.zig").utils.math.zero;
const sub = @import("../../radio.zig").utils.math.sub;
const scalarDiv = @import("../../radio.zig").utils.math.scalarDiv;
const innerProduct = @import("../../radio.zig").utils.math.innerProduct;

////////////////////////////////////////////////////////////////////////////////
// IIR Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn _IIRFilterBlock(comptime T: type, comptime N: comptime_int, comptime M: comptime_int, comptime Context: type) type {
    if (M < 1) {
        @compileLog("Feedback taps length must be at least 1");
    }

    return struct {
        const Self = @This();

        block: Block,
        context: Context,
        b_taps: [N]f32 = [_]f32{0} ** N,
        a_taps: [M]f32 = [_]f32{0} ** M,
        input_state: [N]T = [_]T{zero(T)} ** N,
        output_state: [M - 1]T = [_]T{zero(T)} ** (M - 1),

        pub fn init(context: Context) Self {
            return .{ .block = Block.init(@This()), .context = context };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            for (&self.input_state) |*e| e.* = zero(T);
            for (&self.output_state) |*e| e.* = zero(T);

            if (Context != void) {
                return Context.initialize(self, allocator);
            }
        }

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            for (x, 0..) |_, i| {
                // Shift the input state samples down
                for (self.input_state[1..], 0..) |_, j| self.input_state[N - 1 - j] = self.input_state[N - 2 - j];
                // Insert input sample into input state
                self.input_state[0] = x[i];

                // y[n] = (b[0]*x[n] + b[1]*x[n-1] + b[2]*x[n-2] + ...  - a[1]*y[n-1] - a[2]*y[n-2] - ...) / a[0]
                y[i] = scalarDiv(T, sub(T, innerProduct(T, &self.input_state, &self.b_taps), innerProduct(T, &self.output_state, self.a_taps[1..])), self.a_taps[0]);

                // Shift the output state samples down
                for (self.output_state[1..], 0..) |_, j| self.output_state[M - 2 - j] = self.output_state[M - 3 - j];
                // Insert output sample into output state
                self.output_state[0] = y[i];
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

pub fn IIRFilterBlock(comptime T: type, comptime N: comptime_int, comptime M: comptime_int) type {
    return struct {
        pub fn init(b_taps: [N]f32, a_taps: [M]f32) _IIRFilterBlock(T, N, M, void) {
            var block = _IIRFilterBlock(T, N, M, void).init(void{});
            @memcpy(&block.b_taps, &b_taps);
            @memcpy(&block.a_taps, &a_taps);
            return block;
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
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_taps_3_3_complexfloat32});
    }

    // 5 feedforward taps, 5 feedback taps, ComplexFloat32
    {
        var block = IIRFilterBlock(std.math.Complex(f32), 5, 5).init(vectors.input_taps_5_b, vectors.input_taps_5_a);
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_taps_5_5_complexfloat32});
    }

    // 3 feedforward taps, 3 feedback taps, Float32
    {
        var block = IIRFilterBlock(f32, 3, 3).init(vectors.input_taps_3_b, vectors.input_taps_3_a);
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{f32}, .{&vectors.input_float32}, &[1]type{f32}, .{&vectors.output_taps_3_3_float32});
    }

    // 5 feedforward taps, 5 feedback taps, Float32
    {
        var block = IIRFilterBlock(f32, 5, 5).init(vectors.input_taps_5_b, vectors.input_taps_5_a);
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{f32}, .{&vectors.input_float32}, &[1]type{f32}, .{&vectors.output_taps_5_5_float32});
    }
}
