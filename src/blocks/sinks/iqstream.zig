// @block IQStreamSink
// @description Sink a complex-valued signal to a binary stream, using the
// specified sample format.
// @category Sinks
// @param writer std.io.AnyWriter Writer
// @param format SampleFormat Choice of s8, u8, u16le, u16be, s16le, s16be, u32le, u32be, s32le, s32be, f32le, f32be, f64le, f64be
// @param options Options Additional options
// @signature in:Complex(f32) >
// @usage
// var output_file = try std.fs.cwd().createFile("samples.iq", .{});
// defer output_file.close();
// ...
// var snk = radio.blocks.IQStreamSink.init(output_file.writer().any(), .s16le, .{});
// try top.connect(&src.block, &snk.block);

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const SampleFormat = @import("../../radio.zig").utils.sample_format.SampleFormat;

////////////////////////////////////////////////////////////////////////////////
// IQ Stream Sink
////////////////////////////////////////////////////////////////////////////////

pub const IQStreamSink = struct {
    const Self = @This();

    pub const Options = struct {};

    block: Block,
    writer: std.io.AnyWriter,
    options: Options,

    converter: SampleFormat.Converter,
    buffer: [16384]u8 = undefined,

    pub fn init(writer: std.io.AnyWriter, format: SampleFormat, options: Options) Self {
        return .{ .block = Block.init(@This()), .writer = writer, .options = options, .converter = format.converter() };
    }

    pub fn process(self: *Self, x: []const std.math.Complex(f32)) !ProcessResult {
        var i: usize = 0;
        while (i < x.len) {
            // Convert bytes to samples
            const samples_consumed = @min(self.buffer.len / (2 * self.converter.ELEMENT_SIZE), x.len - i);
            const bytes_produced = self.converter.complexToBytes(x[i .. i + samples_consumed], &self.buffer);
            i += samples_consumed;

            // Write bytes to writer
            try self.writer.writeAll(self.buffer[0..bytes_produced]);
        }

        return ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockFixture = @import("../../radio.zig").testing.BlockFixture;

const vectors = @import("../../vectors/utils/sample_format.zig");

test "IQStreamSink" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    // Basic test
    var block = IQStreamSink.init(fbs.writer().any(), .u16be, .{});
    var fixture = try BlockFixture(&[1]type{std.math.Complex(f32)}, &[0]type{}).init(&block.block, 8000);
    defer fixture.deinit();

    // Test whole vector
    _ = try fixture.process(.{&vectors.input_complex_samples});

    try std.testing.expectEqualSlices(u8, &vectors.bytes_complex_u16be, fbs.getWritten());

    fbs.reset();

    // Test sample by sample
    for (vectors.input_complex_samples) |sample| {
        _ = try fixture.process(.{&[1]std.math.Complex(f32){sample}});
    }

    try std.testing.expectEqualSlices(u8, &vectors.bytes_complex_u16be, fbs.getWritten());
}
