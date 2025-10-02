// @block IQStreamSource
// @description Source a complex-valued signal from a binary stream, using the
// specified sample format.
// @category Sources
// @param reader *std.io.Reader Reader
// @param format SampleFormat Choice of s8, u8, u16le, u16be, s16le, s16be, u32le, u32be, s32le, s32be, f32le, f32be, f64le, f64be
// @param rate f64 Sample rate in Hz
// @param options Options Additional options
// @signature > out1:Complex(f32)
// @usage
// var input_file = try std.fs.cwd().openFile("samples.iq", .{});
// defer input_file.close();
// ...
// var src = radio.blocks.IQStreamSource.init(input_file.reader().any(), .s16le, 1e6, .{});
// try top.connect(&src.block, &snk.block);

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const SampleFormat = @import("../../radio.zig").utils.sample_format.SampleFormat;

////////////////////////////////////////////////////////////////////////////////
// IQ Stream Source
////////////////////////////////////////////////////////////////////////////////

pub const IQStreamSource = struct {
    const Self = @This();

    pub const Options = struct {};

    block: Block,
    reader: *std.io.Reader,
    rate: f64,
    options: Options,

    converter: SampleFormat.Converter,
    buffer: [16384]u8 = undefined,
    offset: usize = 0,

    pub fn init(reader: *std.io.Reader, format: SampleFormat, rate: f64, options: Options) Self {
        return .{ .block = Block.init(@This()), .reader = reader, .rate = rate, .options = options, .converter = format.converter() };
    }

    pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
        self.offset = 0;
    }

    pub fn setRate(self: *Self, _: f64) !f64 {
        return self.rate;
    }

    pub fn process(self: *Self, z: []std.math.Complex(f32)) !ProcessResult {
        // Read into buffer
        const bytes_read = try self.reader.readSliceShort(self.buffer[self.offset..]);
        if (bytes_read == 0 and self.offset < 2 * self.converter.ELEMENT_SIZE) {
            return ProcessResult.EOS;
        }
        self.offset += bytes_read;

        // Convert bytes to samples
        const bytes_consumed = @min(std.mem.alignBackward(usize, self.offset, 2 * self.converter.ELEMENT_SIZE), z.len * 2 * self.converter.ELEMENT_SIZE);
        const samples_produced = self.converter.bytesToComplex(self.buffer[0..bytes_consumed], z);

        // Shift down unused bytes
        for (0..self.offset - bytes_consumed) |i| self.buffer[i] = self.buffer[i + bytes_consumed];
        self.offset -= bytes_consumed;

        return ProcessResult.init(&[0]usize{}, &[1]usize{samples_produced});
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("../../radio.zig").testing.BlockTester;

const vectors = @import("../../vectors/utils/sample_format.zig");

test "IQStreamSource" {
    // Teardown test hook to reset fbs reader between runs
    const hooks = struct {
        fn teardown(context: *anyopaque) !void {
            var reader: *std.io.Reader = @ptrCast(@alignCast(context));
            reader.seek = 0;
        }
    };

    // Basic test
    {
        var reader = std.io.Reader.fixed(&vectors.bytes_complex_u16be);
        var block = IQStreamSource.init(&reader, .u16be, 8000, .{});
        var tester = try BlockTester(&[0]type{}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.checkSource(.{&vectors.samples_complex_u16be}, .{ .context = &reader, .teardown = hooks.teardown });
    }

    // Test cut-off stream
    {
        var reader = std.io.Reader.fixed(vectors.bytes_complex_u16be[0 .. vectors.bytes_complex_u16be.len - 1]);
        var block = IQStreamSource.init(&reader, .u16be, 8000, .{});
        var tester = try BlockTester(&[0]type{}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.checkSource(.{vectors.samples_complex_u16be[0 .. vectors.samples_complex_u16be.len - 1]}, .{ .context = &reader, .teardown = hooks.teardown });
    }
}
