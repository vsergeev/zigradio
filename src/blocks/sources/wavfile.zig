// @block WAVFileSource
// @description Source one or more real-valued signals from a WAV file. The
// supported sample formats are 8-bit unsigned integer, 16-bit signed integer,
// and 32-bit signed integer.
// @category Sources
// @cparam N comptime_int Number of channels: 1 for mono, 2 for stereo
// @param file *std.fs.File File
// @param options Options Additional options:
//      * `repeat_on_eof` (`bool`, repeat on EOF, default false)
// @signature > out1:f32 [out2:f32]
// @usage
// // Source one channel WAV file
// local src = radio.blocks.WAVFileSource(1).init(&input_file, .{});
// try.top.connect(&src.block, &snk.block);
//
// // Source two channel WAV file
// local src = radio.blocks.WAVFileSource(2).init(&input_file, .{});
// // Compose the two channels into a complex-valued signal
// try top.connectPort(&src.block, "out1", &floattocomplex.block, "in1");
// try top.connectPort(&src.block, "out2", &floattocomplex.block, "in2");
// try.top.connect(&floattocomplex.block, &snk.block);

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
// WAV File Source
////////////////////////////////////////////////////////////////////////////////

pub fn WAVFileSource(comptime N: comptime_int) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            repeat_on_eof: bool = false,
        };

        block: Block,
        file: *std.fs.File,
        options: Options,

        rate: u32 = 0,
        reader: std.fs.File.Reader = undefined,
        reader_buffer: [16384]u8 = undefined,
        converter: SampleFormat.Converter = undefined,

        pub fn init(file: *std.fs.File, options: Options) Self {
            return .{ .block = Block.init(@This()), .file = file, .options = options };
        }

        pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
            self.reader = self.file.reader(&self.reader_buffer);

            // Read headers
            const riff_header = try self.reader.interface.takeStruct(RiffHeader, .little);
            const wave_subchunk1_header = try self.reader.interface.takeStruct(WaveSubchunk1Header, .little);
            const wave_subchunk2_header = try self.reader.interface.takeStruct(WaveSubchunk2Header, .little);

            // Check RIFF header
            if (!std.mem.eql(u8, &riff_header.id, "RIFF")) return error.InvalidHeader;
            if (!std.mem.eql(u8, &riff_header.format, "WAVE")) return error.InvalidHeader;

            // Check WAVE Subchunk 1 Header
            if (!std.mem.eql(u8, &wave_subchunk1_header.id, "fmt ")) return error.InvalidHeader;
            if (wave_subchunk1_header.audio_format != 1) return error.UnsupportedAudioFormat;
            if (wave_subchunk1_header.num_channels != N) return error.NumChannelsMismatch;

            // Check WAVE Subchunk 2 Header
            if (!std.mem.eql(u8, &wave_subchunk2_header.id, "data")) return error.InvalidHeader;

            // Pull out sample rate and format
            self.rate = wave_subchunk1_header.sample_rate;
            self.converter = switch (wave_subchunk1_header.bits_per_sample) {
                8 => SampleFormat.u8.converter(),
                16 => SampleFormat.s16le.converter(),
                32 => SampleFormat.s32le.converter(),
                else => return error.UnsupportedBitsPerSample,
            };
        }

        pub fn setRate(self: *Self, _: f64) !f64 {
            return @floatFromInt(self.rate);
        }

        pub fn _process_mono(self: *Self, x: []f32) !ProcessResult {
            // Read bytes
            while (self.reader.interface.bufferedLen() < self.converter.ELEMENT_SIZE) {
                self.reader.interface.fill(self.reader_buffer.len) catch |err| switch (err) {
                    error.EndOfStream => {
                        if (self.options.repeat_on_eof) {
                            try self.reader.seekTo(@sizeOf(RiffHeader) + @sizeOf(WaveSubchunk1Header) + @sizeOf(WaveSubchunk2Header));
                            continue;
                        } else {
                            return ProcessResult.EOS;
                        }
                    },
                    else => |e| return e,
                };
            }

            // Convert bytes to samples
            const bytes_consumed = @min(std.mem.alignBackward(usize, self.reader.interface.bufferedLen(), self.converter.ELEMENT_SIZE), x.len * self.converter.ELEMENT_SIZE);
            const samples_produced = self.converter.bytesToReal(try self.reader.interface.take(bytes_consumed), x);

            return ProcessResult.init(&[0]usize{}, &[1]usize{samples_produced});
        }

        pub fn _process_stereo(self: *Self, x: []f32, y: []f32) !ProcessResult {
            // Read bytes
            while (self.reader.interface.bufferedLen() < 2 * self.converter.ELEMENT_SIZE) {
                self.reader.interface.fill(self.reader_buffer.len) catch |err| switch (err) {
                    error.EndOfStream => {
                        if (self.options.repeat_on_eof) {
                            try self.reader.seekTo(@sizeOf(RiffHeader) + @sizeOf(WaveSubchunk1Header) + @sizeOf(WaveSubchunk2Header));
                            continue;
                        } else {
                            return ProcessResult.EOS;
                        }
                    },
                    else => |e| return e,
                };
            }

            // Convert bytes to samples
            const bytes_consumed = @min(std.mem.alignBackward(usize, self.reader.interface.bufferedLen(), 2 * self.converter.ELEMENT_SIZE), x.len * 2 * self.converter.ELEMENT_SIZE);
            const samples_produced = self.converter.bytesToInterleavedReal(try self.reader.interface.take(bytes_consumed), x, y);

            return ProcessResult.init(&[0]usize{}, &[2]usize{ samples_produced, samples_produced });
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

const BlockTester = @import("../../radio.zig").testing.BlockTester;
const BlockFixture = @import("../../radio.zig").testing.BlockFixture;
const TemporaryFile = @import("../../radio.zig").testing.TemporaryFile;
const expectEqualVectors = @import("../../radio.zig").testing.expectEqualVectors;

const vectors = @import("../../vectors/blocks/sources/wavfile.zig");

test "WAVFileSource" {
    // Create temporary file
    var tmpfile = try TemporaryFile.create();
    defer tmpfile.close();

    // u8, 1 channel
    {
        try tmpfile.write(&vectors.bytes_wavfile_u8_1ch);
        var block = WAVFileSource(1).init(&tmpfile.file, .{});
        var tester = try BlockTester(&[0]type{}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.checkSource(.{&vectors.samples_u8_ch0}, .{});
    }

    // s16, 1 channel
    {
        try tmpfile.write(&vectors.bytes_wavfile_s16_1ch);
        var block = WAVFileSource(1).init(&tmpfile.file, .{});
        var tester = try BlockTester(&[0]type{}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.checkSource(.{&vectors.samples_s16_ch0}, .{});
    }

    // s32, 1 channel
    {
        try tmpfile.write(&vectors.bytes_wavfile_s32_1ch);
        var block = WAVFileSource(1).init(&tmpfile.file, .{});
        var tester = try BlockTester(&[0]type{}, &[1]type{f32}).init(&block.block, 1e-6);
        try tester.checkSource(.{&vectors.samples_s32_ch0}, .{});
    }

    // u8, 2 channel
    {
        try tmpfile.write(&vectors.bytes_wavfile_u8_2ch);
        var block = WAVFileSource(2).init(&tmpfile.file, .{});
        var tester = try BlockTester(&[0]type{}, &[2]type{ f32, f32 }).init(&block.block, 1e-6);
        try tester.checkSource(.{ &vectors.samples_u8_ch0, &vectors.samples_u8_ch1 }, .{});
    }

    // s16, 2 channel
    {
        try tmpfile.write(&vectors.bytes_wavfile_s16_2ch);
        var block = WAVFileSource(2).init(&tmpfile.file, .{});
        var tester = try BlockTester(&[0]type{}, &[2]type{ f32, f32 }).init(&block.block, 1e-6);
        try tester.checkSource(.{ &vectors.samples_s16_ch0, &vectors.samples_s16_ch1 }, .{});
    }

    // s32, 2 channel
    {
        try tmpfile.write(&vectors.bytes_wavfile_s32_2ch);
        var block = WAVFileSource(2).init(&tmpfile.file, .{});
        var tester = try BlockTester(&[0]type{}, &[2]type{ f32, f32 }).init(&block.block, 1e-6);
        try tester.checkSource(.{ &vectors.samples_s32_ch0, &vectors.samples_s32_ch1 }, .{});
    }

    // s16, 1 channel, repeat on eof
    {
        try tmpfile.write(&vectors.bytes_wavfile_s16_1ch);
        var block = WAVFileSource(1).init(&tmpfile.file, .{ .repeat_on_eof = true });
        var fixture = try BlockFixture(&[0]type{}, &[1]type{f32}).init(&block.block, 0);
        defer fixture.deinit();

        for (0..3) |_| {
            const outputs = try fixture.process(.{});
            try std.testing.expectEqual(16, outputs[0].len);
            try expectEqualVectors(f32, &vectors.samples_s16_ch0, outputs[0], 1e-6);
        }
    }

    // s16, 2 channel, repeat on eof
    {
        try tmpfile.write(&vectors.bytes_wavfile_s16_2ch);
        var block = WAVFileSource(2).init(&tmpfile.file, .{ .repeat_on_eof = true });
        var fixture = try BlockFixture(&[0]type{}, &[2]type{ f32, f32 }).init(&block.block, 0);
        defer fixture.deinit();

        for (0..3) |_| {
            const outputs = try fixture.process(.{});
            try std.testing.expectEqual(16, outputs[0].len);
            try std.testing.expectEqual(16, outputs[1].len);
            try expectEqualVectors(f32, &vectors.samples_s16_ch0, outputs[0], 1e-6);
            try expectEqualVectors(f32, &vectors.samples_s16_ch1, outputs[1], 1e-6);
        }
    }

    // Invalid RIFF header id
    {
        var buf = vectors.bytes_wavfile_u8_1ch;
        buf[0] = 'A';
        try tmpfile.write(&buf);
        var block = WAVFileSource(1).init(&tmpfile.file, .{});
        try std.testing.expectError(error.InvalidHeader, block.initialize(std.testing.allocator));
    }

    // Invalid RIFF header format
    {
        var buf = vectors.bytes_wavfile_u8_1ch;
        buf[8] = 'A';
        try tmpfile.write(&buf);
        var block = WAVFileSource(1).init(&tmpfile.file, .{});
        try std.testing.expectError(error.InvalidHeader, block.initialize(std.testing.allocator));
    }

    // Invalid WAVE subchunk 1 header
    {
        var buf = vectors.bytes_wavfile_u8_1ch;
        buf[@sizeOf(RiffHeader)] = 'A';
        try tmpfile.write(&buf);
        var block = WAVFileSource(1).init(&tmpfile.file, .{});
        try std.testing.expectError(error.InvalidHeader, block.initialize(std.testing.allocator));
    }

    // Invalid WAVE subchunk 2 header
    {
        var buf = vectors.bytes_wavfile_u8_1ch;
        buf[@sizeOf(RiffHeader) + @sizeOf(WaveSubchunk1Header)] = 'A';
        try tmpfile.write(&buf);
        var block = WAVFileSource(1).init(&tmpfile.file, .{});
        try std.testing.expectError(error.InvalidHeader, block.initialize(std.testing.allocator));
    }

    // Unsupported audio format
    {
        var buf = vectors.bytes_wavfile_u8_1ch;
        buf[@sizeOf(RiffHeader) + 8] = 2;
        try tmpfile.write(&buf);
        var block = WAVFileSource(1).init(&tmpfile.file, .{});
        try std.testing.expectError(error.UnsupportedAudioFormat, block.initialize(std.testing.allocator));
    }

    // Unsupported bits per sample
    {
        var buf = vectors.bytes_wavfile_u8_1ch;
        buf[@sizeOf(RiffHeader) + 22] = 64;
        try tmpfile.write(&buf);
        var block = WAVFileSource(1).init(&tmpfile.file, .{});
        try std.testing.expectError(error.UnsupportedBitsPerSample, block.initialize(std.testing.allocator));
    }

    // Num channels mismatch
    {
        try tmpfile.write(&vectors.bytes_wavfile_u8_2ch);
        var block = WAVFileSource(1).init(&tmpfile.file, .{});
        try std.testing.expectError(error.NumChannelsMismatch, block.initialize(std.testing.allocator));
    }
}
