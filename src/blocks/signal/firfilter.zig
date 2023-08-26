const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const zero = @import("../../radio.zig").utils.math.zero;
const innerProduct = @import("../../radio.zig").utils.math.innerProduct;

////////////////////////////////////////////////////////////////////////////////
// FIR Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn _FIRFilterBlock(comptime T: type, comptime N: comptime_int, comptime Context: type) type {
    return struct {
        const Self = @This();

        block: Block,
        context: Context,
        taps: [N]f32 = [_]f32{0} ** N,
        state: [N]T = [_]T{zero(T)} ** N,

        pub fn init(context: Context) Self {
            return .{ .block = Block.init(@This()), .context = context };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            for (&self.state) |*e| e.* = zero(T);

            if (Context != void) {
                return Context.initialize(self, allocator);
            }
        }

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            for (x, 0..) |_, i| {
                // Shift the input state samples down
                for (self.state[1..], 0..) |_, j| self.state[N - 1 - j] = self.state[N - 2 - j];
                // Insert input sample into input state
                self.state[0] = x[i];

                // y[n] = b[0]*x[n] + b[1]*x[n-1] + b[2]*x[n-2] + ...
                y[i] = innerProduct(T, &self.state, &self.taps);
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

pub fn FIRFilterBlock(comptime T: type, comptime N: comptime_int) type {
    return struct {
        pub fn init(taps: [N]f32) _FIRFilterBlock(T, N, void) {
            var block = _FIRFilterBlock(T, N, void).init(void{});
            @memcpy(&block.taps, &taps);
            return block;
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/firfilter.zig");

test "FIRFilterBlock" {
    // 1 tap, ComplexFloat32
    {
        var block = FIRFilterBlock(std.math.Complex(f32), 1).init(vectors.input_taps_1);
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_taps_1_complexfloat32});
    }

    // 8 taps, ComplexFloat32
    {
        var block = FIRFilterBlock(std.math.Complex(f32), 8).init(vectors.input_taps_8);
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{std.math.Complex(f32)}, .{&vectors.input_complexfloat32}, &[1]type{std.math.Complex(f32)}, .{&vectors.output_taps_8_complexfloat32});
    }

    // 1 tap, Float32
    {
        var block = FIRFilterBlock(f32, 1).init(vectors.input_taps_1);
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{f32}, .{&vectors.input_float32}, &[1]type{f32}, .{&vectors.output_taps_1_float32});
    }

    // 8 tap, Float32
    {
        var block = FIRFilterBlock(f32, 8).init(vectors.input_taps_8);
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{f32}, .{&vectors.input_float32}, &[1]type{f32}, .{&vectors.output_taps_8_float32});
    }
}
