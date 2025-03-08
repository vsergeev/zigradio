const std = @import("std");
const builtin = @import("builtin");

////////////////////////////////////////////////////////////////////////////////
// Sample Format
////////////////////////////////////////////////////////////////////////////////

pub const SampleFormat = enum {
    s8,
    u8,
    u16le,
    u16be,
    s16le,
    s16be,
    u32le,
    u32be,
    s32le,
    s32be,
    f32le,
    f32be,
    f64le,
    f64be,

    pub const Info = struct {
        data_type: type,
        endianness: ?std.builtin.Endian,
        offset: f32,
        scale: f32,
    };

    pub fn info(self: SampleFormat) Info {
        return switch (self) {
            .u8 => .{ .data_type = u8, .endianness = null, .offset = 127.5, .scale = 127.5 },
            .s8 => .{ .data_type = i8, .endianness = null, .offset = 0, .scale = 127.5 },
            .u16le => .{ .data_type = u16, .endianness = .little, .offset = 32767.5, .scale = 32767.5 },
            .u16be => .{ .data_type = u16, .endianness = .big, .offset = 32767.5, .scale = 32767.5 },
            .s16le => .{ .data_type = i16, .endianness = .little, .offset = 0, .scale = 32767.5 },
            .s16be => .{ .data_type = i16, .endianness = .big, .offset = 0, .scale = 32767.5 },
            .u32le => .{ .data_type = u32, .endianness = .little, .offset = 2147483647.5, .scale = 2147483647.5 },
            .u32be => .{ .data_type = u32, .endianness = .big, .offset = 2147483647.5, .scale = 2147483647.5 },
            .s32le => .{ .data_type = i32, .endianness = .little, .offset = 0, .scale = 2147483647.5 },
            .s32be => .{ .data_type = i32, .endianness = .big, .offset = 0, .scale = 2147483647.5 },
            .f32le => .{ .data_type = f32, .endianness = .little, .offset = 0, .scale = 1.0 },
            .f32be => .{ .data_type = f32, .endianness = .big, .offset = 0, .scale = 1.0 },
            .f64le => .{ .data_type = f64, .endianness = .little, .offset = 0, .scale = 1.0 },
            .f64be => .{ .data_type = f64, .endianness = .big, .offset = 0, .scale = 1.0 },
        };
    }

    pub const Converter = struct {
        ELEMENT_SIZE: usize,
        bytesToComplex: *const fn (bytes: []u8, samples: []std.math.Complex(f32)) usize,
        complexToBytes: *const fn (samples: []const std.math.Complex(f32), bytes: []u8) usize,
        bytesToReal: *const fn (bytes: []u8, samples: []f32) usize,
        realToBytes: *const fn (samples: []const f32, bytes: []u8) usize,
    };

    pub fn converter(self: SampleFormat) Converter {
        return _converters[@intFromEnum(self)];
    }

    const _converters = _generate();
};

////////////////////////////////////////////////////////////////////////////
// Code Generation
////////////////////////////////////////////////////////////////////////////

pub fn _generate() [@typeInfo(SampleFormat).@"enum".fields.len]SampleFormat.Converter {
    var converters: [@typeInfo(SampleFormat).@"enum".fields.len]SampleFormat.Converter = undefined;

    for (0..converters.len) |e| {
        const info = SampleFormat.info(@enumFromInt(e));

        const gen = struct {
            fn swapBytes(bytes: []u8) void {
                if (comptime info.endianness == null or info.endianness.? == builtin.cpu.arch.endian()) return;

                const buf = std.mem.bytesAsSlice(std.meta.Int(.unsigned, 8 * @sizeOf(info.data_type)), bytes);
                for (buf) |*elem| elem.* = @byteSwap(elem.*);
            }

            fn bytesToComplex(bytes: []u8, samples: []std.math.Complex(f32)) usize {
                std.debug.assert(bytes.len <= samples.len * 2 * @sizeOf(info.data_type));

                swapBytes(bytes);

                const buf = std.mem.bytesAsSlice(info.data_type, bytes);
                for (0..buf.len / 2) |i| {
                    samples[i].re = (std.math.lossyCast(f32, buf[2 * i]) - info.offset) / info.scale;
                    samples[i].im = (std.math.lossyCast(f32, buf[2 * i + 1]) - info.offset) / info.scale;
                }

                return buf.len / 2;
            }

            fn complexToBytes(samples: []const std.math.Complex(f32), bytes: []u8) usize {
                std.debug.assert(samples.len * 2 * @sizeOf(info.data_type) <= bytes.len);

                const buf = std.mem.bytesAsSlice(info.data_type, bytes);
                for (0..samples.len) |i| {
                    buf[2 * i] = std.math.lossyCast(info.data_type, (samples[i].re * info.scale) + info.offset);
                    buf[2 * i + 1] = std.math.lossyCast(info.data_type, (samples[i].im * info.scale) + info.offset);
                }

                swapBytes(bytes[0 .. samples.len * 2 * @sizeOf(info.data_type)]);

                return samples.len * 2 * @sizeOf(info.data_type);
            }

            fn bytesToReal(bytes: []u8, samples: []f32) usize {
                std.debug.assert(bytes.len <= samples.len * @sizeOf(info.data_type));

                swapBytes(bytes);

                const buf = std.mem.bytesAsSlice(info.data_type, bytes);
                for (0..buf.len) |i| {
                    samples[i] = (std.math.lossyCast(f32, buf[i]) - info.offset) / info.scale;
                }

                return buf.len;
            }

            fn realToBytes(samples: []const f32, bytes: []u8) usize {
                std.debug.assert(samples.len * @sizeOf(info.data_type) <= bytes.len);

                const buf = std.mem.bytesAsSlice(info.data_type, bytes);
                for (0..samples.len) |i| {
                    buf[i] = std.math.lossyCast(info.data_type, (samples[i] * info.scale) + info.offset);
                }

                swapBytes(bytes[0 .. samples.len * @sizeOf(info.data_type)]);

                return samples.len * @sizeOf(info.data_type);
            }
        };

        converters[e] = .{
            .ELEMENT_SIZE = @sizeOf(info.data_type),
            .bytesToComplex = gen.bytesToComplex,
            .complexToBytes = gen.complexToBytes,
            .bytesToReal = gen.bytesToReal,
            .realToBytes = gen.realToBytes,
        };
    }

    return converters;
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const expectEqualVectors = @import("../core/testing.zig").expectEqualVectors;

const vectors = @import("../vectors/utils/sample_format.zig");

test "SampleFormat bytesToComplex" {
    inline for (comptime std.enums.values(SampleFormat)) |e| {
        const input_vector = @field(vectors, "bytes_complex_" ++ @tagName(e));
        const output_vector = @field(vectors, "samples_complex_" ++ @tagName(e));

        var input: [input_vector.len]u8 = input_vector;
        var output: [16]std.math.Complex(f32) = undefined;
        try std.testing.expectEqual(output_vector.len, SampleFormat.converter(e).bytesToComplex(&input, &output));
        try expectEqualVectors(std.math.Complex(f32), &output_vector, output[0..output_vector.len], 1e-6);
    }
}

test "SampleFormat complexToBytes" {
    inline for (comptime std.enums.values(SampleFormat)) |e| {
        const input_vector = vectors.input_complex_samples;
        const output_vector = @field(vectors, "bytes_complex_" ++ @tagName(e));

        var output: [output_vector.len * 2]u8 = undefined;
        try std.testing.expectEqual(output_vector.len, SampleFormat.converter(e).complexToBytes(&input_vector, &output));
        try std.testing.expectEqualSlices(u8, &output_vector, output[0..output_vector.len]);
    }
}

test "SampleFormat bytesToReal" {
    inline for (comptime std.enums.values(SampleFormat)) |e| {
        const input_vector = @field(vectors, "bytes_real_" ++ @tagName(e));
        const output_vector = @field(vectors, "samples_real_" ++ @tagName(e));

        var input: [input_vector.len]u8 = input_vector;
        var output: [16]f32 = undefined;
        try std.testing.expectEqual(output_vector.len, SampleFormat.converter(e).bytesToReal(&input, &output));
        try expectEqualVectors(f32, &output_vector, output[0..output_vector.len], 1e-6);
    }
}

test "SampleFormat realToBytes" {
    inline for (comptime std.enums.values(SampleFormat)) |e| {
        const input_vector = vectors.input_real_samples;
        const output_vector = @field(vectors, "bytes_real_" ++ @tagName(e));

        var output: [output_vector.len * 2]u8 = undefined;
        try std.testing.expectEqual(output_vector.len, SampleFormat.converter(e).realToBytes(&input_vector, &output));
        try std.testing.expectEqualSlices(u8, &output_vector, output[0..output_vector.len]);
    }
}
