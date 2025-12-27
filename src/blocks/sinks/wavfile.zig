// @block WAVFileSink
// @description Sink one or more real-valued signals to a WAV file. The
// supported sample formats are 8-bit unsigned integer, 16-bit signed integer,
// and 32-bit signed integer.
// @category Sinks
// @cparam N comptime_int Number of channels: 1 for mono, 2 for stereo
// @param file *std.fs.File File
// @param options Options Additional options
//      * `format` (`Format`, choice of `.u8`, `.s16`, `.s32`, default `.s16`)
// @signature in1:f32 [in2:f32] >
// @usage
// // Sink to a one channel WAV file
// var snk = radio.blocks.WAVFileSink(1).init(&output_file, .{});
// try top.connect(&src.block, &snk.block);
//
// // Sink to a two channel WAV file
// var snk = radio.blocks.WAVFileSink(2).init(&output_file, .{});
// try top.connectPort(&src_left.block, "out", &snk.block, "in1");
// try top.connectPort(&src_right.block, "out", &snk.block, "in2");

const std = @import("std");
const builtin = @import("builtin");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const SampleFormat = @import("../../radio.zig").utils.sample_format.SampleFormat;

////////////////////////////////////////////////////////////////////////////////
// WAV Header Types
////////////////////////////////////////////////////////////////////////////////

const RiffHeader = extern struct {
    id: [4]u8,
    size: u32,
    format: [4]u8,
};

const WaveSubchunk1Header = extern struct {
    id: [4]u8,
    size: u32,
    audio_format: u16,
    num_channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
};

const WaveSubchunk2Header = extern struct {
    id: [4]u8,
    size: u32,
};

////////////////////////////////////////////////////////////////////////////////
// WAV File Sink
////////////////////////////////////////////////////////////////////////////////

pub fn WAVFileSink(comptime N: comptime_int) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            format: enum { u8, s16, s32 } = .s16,
        };

        block: Block,
        file: *std.fs.File,
        options: Options,
        converter: SampleFormat.Converter,

        writer: std.fs.File.Writer = undefined,
        writer_buffer: [16384]u8 = undefined,
        samples_written: usize = 0,

        pub fn init(file: *std.fs.File, options: Options) Self {
            return .{
                .block = Block.init(@This()),
                .file = file,
                .options = options,
                .converter = switch (options.format) {
                    .u8 => SampleFormat.u8.converter(),
                    .s16 => SampleFormat.s16le.converter(),
                    .s32 => SampleFormat.s32le.converter(),
                },
            };
        }

        pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
            self.writer = self.file.writer(&self.writer_buffer);
            self.samples_written = 0;

            // Seek past WAV headers (populated on cleanup)
            try self.writer.seekTo(@sizeOf(RiffHeader) + @sizeOf(WaveSubchunk1Header) + @sizeOf(WaveSubchunk2Header));
        }

        pub fn deinitialize(self: *Self, _: std.mem.Allocator) void {
            // Lookup bits per sample
            const bits_per_sample: usize = switch (self.options.format) {
                .u8 => 8,
                .s16 => 16,
                .s32 => 32,
            };

            // Prepare headers
            const riff_header: RiffHeader = .{
                .id = .{ 'R', 'I', 'F', 'F' },
                .size = @intCast(4 + @sizeOf(WaveSubchunk1Header) + @sizeOf(WaveSubchunk2Header) + self.samples_written * N * (bits_per_sample / 8)),
                .format = .{ 'W', 'A', 'V', 'E' },
            };
            const wave_subchunk1_header: WaveSubchunk1Header = .{
                .id = .{ 'f', 'm', 't', ' ' },
                .size = 16,
                .audio_format = 1,
                .num_channels = N,
                .sample_rate = self.block.getRate(u32),
                .byte_rate = @intCast(self.block.getRate(usize) * N * (bits_per_sample / 8)),
                .block_align = @intCast(N * (bits_per_sample / 8)),
                .bits_per_sample = @intCast(bits_per_sample),
            };
            const wave_subchunk2_header: WaveSubchunk2Header = .{
                .id = .{ 'd', 'a', 't', 'a' },
                .size = @intCast(self.samples_written * N * (bits_per_sample / 8)),
            };

            // FIXME need a cleanup hook that can return an error instead of
            // using deinitialize()

            // Flush writer
            self.writer.interface.flush() catch {};

            // Rewind writer
            self.writer.seekTo(0) catch {};

            // Write headers
            self.writer.interface.writeStruct(riff_header, .little) catch {};
            self.writer.interface.writeStruct(wave_subchunk1_header, .little) catch {};
            self.writer.interface.writeStruct(wave_subchunk2_header, .little) catch {};

            // Flush writer
            self.writer.interface.flush() catch {};
        }

        pub fn _process_mono(self: *Self, x: []const f32) !ProcessResult {
            var i: usize = 0;
            while (i < x.len) {
                // Flush when write buffer is full
                if (self.writer.interface.unusedCapacityLen() < self.converter.ELEMENT_SIZE) {
                    try self.writer.interface.flush();
                }

                // Convert bytes to samples
                const samples_consumed = @min(self.writer.interface.unusedCapacityLen() / self.converter.ELEMENT_SIZE, x.len - i);
                _ = self.converter.realToBytes(x[i .. i + samples_consumed], try self.writer.interface.writableSlice(samples_consumed * self.converter.ELEMENT_SIZE));

                self.samples_written += samples_consumed;
                i += samples_consumed;
            }

            return ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
        }

        pub fn _process_stereo(self: *Self, x: []const f32, y: []const f32) !ProcessResult {
            var i: usize = 0;
            while (i < x.len) {
                // Flush when write buffer is full
                if (self.writer.interface.unusedCapacityLen() < 2 * self.converter.ELEMENT_SIZE) {
                    try self.writer.interface.flush();
                }

                // Convert bytes to samples
                const samples_consumed = @min(self.writer.interface.unusedCapacityLen() / (2 * self.converter.ELEMENT_SIZE), x.len - i);
                _ = self.converter.interleavedRealToBytes(x[i .. i + samples_consumed], y[i .. i + samples_consumed], try self.writer.interface.writableSlice(samples_consumed * 2 * self.converter.ELEMENT_SIZE));

                self.samples_written += samples_consumed;
                i += samples_consumed;
            }

            return ProcessResult.init(&[2]usize{ x.len, y.len }, &[0]usize{});
        }

        pub const process = switch (N) {
            1 => _process_mono,
            2 => _process_stereo,
            else => @compileError("Only one or two channels supported."),
        };
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockFixture = @import("../../radio.zig").testing.BlockFixture;
const TemporaryFile = @import("../../radio.zig").testing.TemporaryFile;

const vectors = @import("../../vectors/blocks/sources/wavfile.zig");

test "WAVFileSink" {
    // Create temporary file
    var tmpfile = try TemporaryFile.create();
    defer tmpfile.close();

    // u8, 1 channel
    {
        try tmpfile.write(&.{});

        var block = WAVFileSink(1).init(&tmpfile.file, .{ .format = .u8 });
        var fixture = try BlockFixture(&[1]type{f32}, &[0]type{}).init(&block.block, 44100);
        _ = try fixture.process(.{&vectors.samples_ch0});
        fixture.deinit();

        var buf: [256]u8 = undefined;
        const count = try tmpfile.read(&buf);
        try std.testing.expectEqualSlices(u8, &vectors.bytes_wavfile_u8_1ch, buf[0..count]);
    }

    // s16, 1 channel
    {
        try tmpfile.write(&.{});

        var block = WAVFileSink(1).init(&tmpfile.file, .{ .format = .s16 });
        var fixture = try BlockFixture(&[1]type{f32}, &[0]type{}).init(&block.block, 44100);
        _ = try fixture.process(.{&vectors.samples_ch0});
        fixture.deinit();

        var buf: [256]u8 = undefined;
        const count = try tmpfile.read(&buf);
        try std.testing.expectEqualSlices(u8, &vectors.bytes_wavfile_s16_1ch, buf[0..count]);
    }

    // s32, 1 channel
    {
        try tmpfile.write(&.{});

        var block = WAVFileSink(1).init(&tmpfile.file, .{ .format = .s32 });
        var fixture = try BlockFixture(&[1]type{f32}, &[0]type{}).init(&block.block, 44100);
        _ = try fixture.process(.{&vectors.samples_ch0});
        fixture.deinit();

        var buf: [256]u8 = undefined;
        const count = try tmpfile.read(&buf);
        try std.testing.expectEqualSlices(u8, &vectors.bytes_wavfile_s32_1ch, buf[0..count]);
    }

    // u8, 2 channel
    {
        try tmpfile.write(&.{});

        var block = WAVFileSink(2).init(&tmpfile.file, .{ .format = .u8 });
        var fixture = try BlockFixture(&[2]type{ f32, f32 }, &[0]type{}).init(&block.block, 44100);
        _ = try fixture.process(.{ &vectors.samples_ch0, &vectors.samples_ch1 });
        fixture.deinit();

        var buf: [256]u8 = undefined;
        const count = try tmpfile.read(&buf);
        try std.testing.expectEqualSlices(u8, &vectors.bytes_wavfile_u8_2ch, buf[0..count]);
    }

    // s16, 2 channel
    {
        try tmpfile.write(&.{});

        var block = WAVFileSink(2).init(&tmpfile.file, .{ .format = .s16 });
        var fixture = try BlockFixture(&[2]type{ f32, f32 }, &[0]type{}).init(&block.block, 44100);
        _ = try fixture.process(.{ &vectors.samples_ch0, &vectors.samples_ch1 });
        fixture.deinit();

        var buf: [256]u8 = undefined;
        const count = try tmpfile.read(&buf);
        try std.testing.expectEqualSlices(u8, &vectors.bytes_wavfile_s16_2ch, buf[0..count]);
    }

    // s32, 2 channel
    {
        try tmpfile.write(&.{});

        var block = WAVFileSink(2).init(&tmpfile.file, .{ .format = .s32 });
        var fixture = try BlockFixture(&[2]type{ f32, f32 }, &[0]type{}).init(&block.block, 44100);
        _ = try fixture.process(.{ &vectors.samples_ch0, &vectors.samples_ch1 });
        fixture.deinit();

        var buf: [256]u8 = undefined;
        const count = try tmpfile.read(&buf);
        try std.testing.expectEqualSlices(u8, &vectors.bytes_wavfile_s32_2ch, buf[0..count]);
    }
}
