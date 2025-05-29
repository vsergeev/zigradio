const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// JSON Stream Sink
////////////////////////////////////////////////////////////////////////////////

pub fn JSONStreamSink(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Options = struct {};

        block: Block,
        writer: std.io.AnyWriter,
        options: Options,

        pub fn init(writer: std.io.AnyWriter, options: Options) Self {
            return .{ .block = Block.init(@This()), .writer = writer, .options = options };
        }

        pub fn process(self: *Self, x: []const T) !ProcessResult {
            for (x) |e| {
                try std.json.stringify(e, .{}, self.writer);
                try self.writer.writeAll("\n");
            }

            return ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockFixture = @import("../../radio.zig").testing.BlockFixture;

test "JSONStreamSink" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const Foo = struct {
        a: u32,
        b: []const u8,
        c: bool,

        pub fn typeName() []const u8 {
            return "Foo";
        }
    };

    const input_samples: [3]Foo = .{ .{ .a = 123, .b = "foo", .c = true }, .{ .a = 456, .b = "bar", .c = false }, .{ .a = 789, .b = "qux", .c = true } };
    const output_json: []const u8 = "{\"a\":123,\"b\":\"foo\",\"c\":true}\n{\"a\":456,\"b\":\"bar\",\"c\":false}\n{\"a\":789,\"b\":\"qux\",\"c\":true}\n";

    // Basic test
    var block = JSONStreamSink(Foo).init(fbs.writer().any(), .{});
    var fixture = try BlockFixture(&[1]type{Foo}, &[0]type{}).init(&block.block, 8000);
    defer fixture.deinit();

    // Test whole vector
    _ = try fixture.process(.{&input_samples});

    try std.testing.expectEqualSlices(u8, output_json, fbs.getWritten());

    fbs.reset();

    // Test sample by sample
    for (input_samples) |sample| {
        _ = try fixture.process(.{&[1]Foo{sample}});
    }

    try std.testing.expectEqualSlices(u8, output_json, fbs.getWritten());
}
