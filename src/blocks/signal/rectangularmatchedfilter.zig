// @block RectangularMatchedFilterBlock
// @description Correlate a real-valued signal with a rectangular matched
// filter.
// @category Filtering
// @param baudrate Baudrate
// @signature in1:f32 > out1:f32
// @usage
// var matched_filter = radio.blocks.RectangularMatchedFilterBlock.init(2400);

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const FIRFilter = @import("./firfilter.zig").FIRFilter;

////////////////////////////////////////////////////////////////////////////////
// Rectangular Matched Filter Block
////////////////////////////////////////////////////////////////////////////////

pub const RectangularMatchedFilterBlock = struct {
    block: Block,
    baudrate: f32,
    filter: FIRFilter(f32, f32),

    pub fn init(baudrate: f32) RectangularMatchedFilterBlock {
        return .{ .block = Block.init(@This()), .baudrate = baudrate, .filter = FIRFilter(f32, f32).init() };
    }

    pub fn initialize(self: *RectangularMatchedFilterBlock, allocator: std.mem.Allocator) !void {
        // Generate taps
        const taps = try allocator.alloc(f32, @intFromFloat(self.block.getRate(f32) / self.baudrate));
        defer allocator.free(taps);
        @memset(taps, 1.0 / @as(f32, @floatFromInt(taps.len)));

        // Initialize filter
        return self.filter.initialize(allocator, taps[0..]);
    }

    pub fn deinitialize(self: *RectangularMatchedFilterBlock, allocator: std.mem.Allocator) void {
        self.filter.deinitialize(allocator);
    }

    pub fn process(self: *RectangularMatchedFilterBlock, x: []const f32, y: []f32) !ProcessResult {
        return self.filter.process(x, y);
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/blocks/signal/rectangularmatchedfilter.zig");

test "RectangularMatchedFilterBlock" {
    // 2400 baudrate
    {
        var block = RectangularMatchedFilterBlock.init(2400);
        var tester = try BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.check(96e3, .{&vectors.input_float32}, .{&vectors.output_baudrate_2400}, .{});
    }
}
