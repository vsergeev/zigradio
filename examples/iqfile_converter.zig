const std = @import("std");

const radio = @import("radio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    if (args.len < 5) {
        std.debug.print("Usage: {s} <input IQ file> <input format> <output IQ file> <output format>\n", .{args[0]});
        std.debug.print("Supported formats: u8, s8, u16le, u16be, s16le, s16be, u32le, u32be, s32le, s32be, f32le, f32be, f64le, f64be\n", .{});
        std.posix.exit(1);
    }

    const input_format = std.meta.stringToEnum(radio.utils.sample_format.SampleFormat, args[2]) orelse return error.InvalidArgument;
    const output_format = std.meta.stringToEnum(radio.utils.sample_format.SampleFormat, args[4]) orelse return error.InvalidArgument;

    var input_file = try std.fs.cwd().openFile(args[1], .{});
    defer input_file.close();
    var output_file = try std.fs.cwd().createFile(args[3], .{});
    defer output_file.close();

    var input_reader = input_file.reader(&.{});
    var output_writer = output_file.writer(&.{});

    var source = radio.blocks.IQStreamSource.init(&input_reader.interface, input_format, 0, .{});
    var sink = radio.blocks.IQStreamSink.init(&output_writer.interface, output_format, .{});

    var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
    defer top.deinit();
    try top.connect(&source.block, &sink.block);

    _ = try top.run();
}
