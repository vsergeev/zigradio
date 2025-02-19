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
    reader: std.io.AnyReader,
    rate: f64,
    options: Options,

    converter: SampleFormat.Converter,
    buffer: [16384]u8 = undefined,
    offset: usize = 0,

    pub fn init(reader: std.io.AnyReader, format: SampleFormat, rate: f64, options: Options) Self {
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
        const bytes_read = try self.reader.read(self.buffer[self.offset..]);
        if (bytes_read == 0 and self.offset < 2 * self.converter.ELEMENT_SIZE) {
            return ProcessResult.eos();
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
            var fbs: *std.io.FixedBufferStream([]const u8) = @ptrCast(@alignCast(context));
            fbs.reset();
        }
    };

    // Basic test
    {
        var fbs = std.io.fixedBufferStream(&vectors.bytes_complex_u16be);
        var block = IQStreamSource.init(fbs.reader().any(), .u16be, 8000, .{});
        var tester = try BlockTester(&[0]type{}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.checkSource(.{&vectors.samples_complex_u16be}, .{ .context = &fbs, .teardown = hooks.teardown });
    }

    // Test cut-off stream
    {
        var fbs = std.io.fixedBufferStream(vectors.bytes_complex_u16be[0 .. vectors.bytes_complex_u16be.len - 1]);
        var block = IQStreamSource.init(fbs.reader().any(), .u16be, 8000, .{});
        var tester = try BlockTester(&[0]type{}, &[1]type{std.math.Complex(f32)}).init(&block.block, 1e-6);
        try tester.checkSource(.{vectors.samples_complex_u16be[0 .. vectors.samples_complex_u16be.len - 1]}, .{ .context = &fbs, .teardown = hooks.teardown });
    }
}
