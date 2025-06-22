const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const platform = @import("../../radio.zig").platform;

////////////////////////////////////////////////////////////////////////////////
// Delay Block
////////////////////////////////////////////////////////////////////////////////

pub fn DelayBlock(comptime T: type) type {
    return struct {
        const Self = @This();

        block: Block,
        delay: usize,
        state: []T = &[0]T{},

        pub fn init(delay: usize) Self {
            return .{ .block = Block.init(@This()), .delay = delay };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            self.state = try allocator.alloc(T, self.delay);
        }

        pub fn deinitialize(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.state);
        }

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            const n: usize = @min(self.state.len, x.len);
            const m: usize = if (x.len > n) x.len - n else 0;

            // Shift out state
            @memcpy(y[0..n], self.state[0..n]);
            // Shift out input
            @memcpy(y[n .. n + m], x[0..m]);
            // Shift into state
            for (self.state[0 .. self.state.len - n], self.state[n..]) |*d, s| d.* = s;
            @memcpy(self.state[self.state.len - n ..], x[m..]);

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/delay.zig");

test "DelayBlock" {
    // ComplexFloat32, delay 7
    {
        var block = DelayBlock(std.math.Complex(f32)).init(7);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_complexfloat32}, .{&vectors.output_delay_7_complexfloat32}, .{});
    }

    // Float32, delay 7
    {
        var block = DelayBlock(f32).init(7);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(2, .{&vectors.input_float32}, .{&vectors.output_delay_7_float32}, .{});
    }
}
