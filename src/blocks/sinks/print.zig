const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// Print Sink
////////////////////////////////////////////////////////////////////////////////

pub fn PrintSink(comptime T: type) type {
    return struct {
        const Self = @This();

        block: Block,

        pub fn init() Self {
            return .{ .block = Block.init(@This()) };
        }

        pub fn process(_: *Self, x: []const T) !ProcessResult {
            for (x) |e| std.debug.print("{any}\n", .{e});

            return ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
        }
    };
}
