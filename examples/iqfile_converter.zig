const std = @import("std");

const radio = @import("radio");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    const prog = args_it.next() orelse "example";
    const input_path = args_it.next();
    const input_format_arg = args_it.next();
    const output_path = args_it.next();
    const output_format_arg = args_it.next();
    if (output_format_arg == null) {
        std.debug.print("Usage: {s} <input IQ file> <input format> <output IQ file> <output format>\n", .{prog});
        std.debug.print("Supported formats: u8, s8, u16le, u16be, s16le, s16be, u32le, u32be, s32le, s32be, f32le, f32be, f64le, f64be\n", .{});
        std.process.exit(1);
    }

    const input_format = std.meta.stringToEnum(radio.utils.sample_format.SampleFormat, input_format_arg.?) orelse return error.InvalidArgument;
    const output_format = std.meta.stringToEnum(radio.utils.sample_format.SampleFormat, output_format_arg.?) orelse return error.InvalidArgument;

    var input_file = try std.Io.Dir.cwd().openFile(io, input_path.?, .{});
    defer input_file.close(io);
    var output_file = try std.Io.Dir.cwd().createFile(io, output_path.?, .{});
    defer output_file.close(io);

    var input_reader = input_file.reader(io, &.{});
    var output_writer = output_file.writer(io, &.{});

    var source = radio.blocks.IQStreamSource.init(&input_reader.interface, input_format, 0, .{});
    var sink = radio.blocks.IQStreamSink.init(&output_writer.interface, output_format, .{});

    var top = radio.Flowgraph.init(init.gpa, .{ .debug = true });
    defer top.deinit();
    try top.connect(&source.block, &sink.block);

    _ = try top.run();
}
