const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const FIRFilter = @import("./firfilter.zig").FIRFilter;

const firRootRaisedCosine = @import("../../radio.zig").utils.filter.firRootRaisedCosine;

////////////////////////////////////////////////////////////////////////////////
// Root Raised Cosine Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn RootRaisedCosineFilterBlock(comptime T: type, comptime N: comptime_int) type {
    return struct {
        const Self = @This();

        block: Block,
        beta: f32,
        symbol_rate: f32,
        filter: FIRFilter(T, f32),

        pub fn init(beta: f32, symbol_rate: f32) Self {
            return .{ .block = Block.init(@This()), .beta = beta, .symbol_rate = symbol_rate, .filter = FIRFilter(T, f32).init() };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            // Generate taps
            const taps = firRootRaisedCosine(N, self.block.getRate(f32), self.beta, 1 / self.symbol_rate);

            // Initialize filter
            return self.filter.initialize(allocator, taps[0..]);
        }

        pub fn deinitialize(self: *Self, allocator: std.mem.Allocator) void {
            self.filter.deinitialize(allocator);
        }

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            return self.filter.process(x, y);
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/rootraisedcosinefilter.zig");

test "RootRaisedCosineFilterBlock" {
    // 101 taps, 0.5 beta, 1200 symbol rate
    {
        var block = RootRaisedCosineFilterBlock(f32, 101).init(0.5, 1200);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(24e3, .{&vectors.input_float32}, .{&vectors.output_taps_101_beta_0_5_symbol_rate_1200_float32}, .{});
    }

    // 101 taps, 0.5 beta, 1200 symbol rate
    {
        var block = RootRaisedCosineFilterBlock(std.math.Complex(f32), 101).init(0.5, 1200);
        var tester = try BlockTester(&[1]type{std.math.Complex(f32)}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.check(24e3, .{&vectors.input_complexfloat32}, .{&vectors.output_taps_101_beta_0_5_symbol_rate_1200_complexfloat32}, .{});
    }
}
