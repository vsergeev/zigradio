const std = @import("std");

const radio = @import("radio");

////////////////////////////////////////////////////////////////////////////////
// Constants
////////////////////////////////////////////////////////////////////////////////

const BENCHMARK_TRIAL_DURATION_MS = 5000;

////////////////////////////////////////////////////////////////////////////////
// Helpers
////////////////////////////////////////////////////////////////////////////////

fn benchmark_run(flowgraph: *radio.Flowgraph) !void {
    try flowgraph.start();
    std.time.sleep(BENCHMARK_TRIAL_DURATION_MS * 1e6);
    _ = try flowgraph.stop();
}

fn generate_taps(comptime T: type, comptime N: comptime_int) [N]T {
    var taps: [N]T = undefined;
    var prng = std.rand.DefaultPrng.init(123);
    for (&taps) |*tap| tap.* = if (T == f32) prng.random().float(f32) else .{ .re = prng.random().float(f32), .im = prng.random().float(f32) };
    return taps;
}

////////////////////////////////////////////////////////////////////////////////
// Benchmarks
////////////////////////////////////////////////////////////////////////////////

fn benchmark_fir_filter_five_back_to_back(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(std.math.Complex(f32)).init(1.0);
    var dut1 = radio.blocks.FIRFilterBlock(std.math.Complex(f32), f32, 256).init(generate_taps(f32, 256));
    var dut2 = radio.blocks.FIRFilterBlock(std.math.Complex(f32), f32, 256).init(generate_taps(f32, 256));
    var dut3 = radio.blocks.FIRFilterBlock(std.math.Complex(f32), f32, 256).init(generate_taps(f32, 256));
    var dut4 = radio.blocks.FIRFilterBlock(std.math.Complex(f32), f32, 256).init(generate_taps(f32, 256));
    var dut5 = radio.blocks.FIRFilterBlock(std.math.Complex(f32), f32, 256).init(generate_taps(f32, 256));
    var sink = radio.blocks.BenchmarkSink(std.math.Complex(f32)).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut1.block);
    try top.connect(&dut1.block, &dut2.block);
    try top.connect(&dut2.block, &dut3.block);
    try top.connect(&dut3.block, &dut4.block);
    try top.connect(&dut4.block, &dut5.block);
    try top.connect(&dut5.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_zero_source_complex(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(std.math.Complex(f32)).init(1.0);
    var sink = radio.blocks.BenchmarkSink(std.math.Complex(f32)).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_zero_source_real(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(f32).init(1.0);
    var sink = radio.blocks.BenchmarkSink(f32).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_signal_source_cosine(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.SignalSource.init(.Cosine, 100e3, 1e6, .{});
    var sink = radio.blocks.BenchmarkSink(f32).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_signal_source_square(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.SignalSource.init(.Square, 100e3, 1e6, .{});
    var sink = radio.blocks.BenchmarkSink(f32).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_fir_filter_complex_taps_complex_input(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(std.math.Complex(f32)).init(1.0);
    var dut = radio.blocks.FIRFilterBlock(std.math.Complex(f32), std.math.Complex(f32), 128).init(generate_taps(std.math.Complex(f32), 128));
    var sink = radio.blocks.BenchmarkSink(std.math.Complex(f32)).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_fir_filter_real_taps_complex_input(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(std.math.Complex(f32)).init(1.0);
    var dut = radio.blocks.FIRFilterBlock(std.math.Complex(f32), f32, 128).init(generate_taps(f32, 128));
    var sink = radio.blocks.BenchmarkSink(std.math.Complex(f32)).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_fir_filter_real_taps_real_input(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(f32).init(1.0);
    var dut = radio.blocks.FIRFilterBlock(f32, f32, 128).init(generate_taps(f32, 128));
    var sink = radio.blocks.BenchmarkSink(f32).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_iir_filter_real_taps_complex_input(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(std.math.Complex(f32)).init(1.0);
    var dut = radio.blocks.IIRFilterBlock(std.math.Complex(f32), 5, 3).init(generate_taps(f32, 5), generate_taps(f32, 3));
    var sink = radio.blocks.BenchmarkSink(std.math.Complex(f32)).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_iir_filter_real_taps_real_input(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(f32).init(1.0);
    var dut = radio.blocks.IIRFilterBlock(f32, 5, 3).init(generate_taps(f32, 5), generate_taps(f32, 3));
    var sink = radio.blocks.BenchmarkSink(f32).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_fm_deemphasis_filter(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(f32).init(30e3);
    var dut = radio.blocks.FMDeemphasisFilterBlock.init(75e-6);
    var sink = radio.blocks.BenchmarkSink(f32).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_downsampler_complex(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(std.math.Complex(f32)).init(1.0);
    var dut = radio.blocks.DownsamplerBlock(std.math.Complex(f32)).init(5);
    var sink = radio.blocks.BenchmarkSink(std.math.Complex(f32)).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_downsampler_real(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(f32).init(1.0);
    var dut = radio.blocks.DownsamplerBlock(f32).init(5);
    var sink = radio.blocks.BenchmarkSink(f32).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_frequency_translator(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(std.math.Complex(f32)).init(1e6);
    var dut = radio.blocks.FrequencyTranslatorBlock.init(200e3);
    var sink = radio.blocks.BenchmarkSink(std.math.Complex(f32)).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_frequency_discriminator(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(std.math.Complex(f32)).init(1);
    var dut = radio.blocks.FrequencyDiscriminatorBlock.init(1.25);
    var sink = radio.blocks.BenchmarkSink(f32).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_complex_magnitude(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(std.math.Complex(f32)).init(1);
    var dut = radio.blocks.ComplexMagnitudeBlock.init();
    var sink = radio.blocks.BenchmarkSink(f32).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_complex_to_real(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(std.math.Complex(f32)).init(1);
    var dut = radio.blocks.ComplexToRealBlock.init();
    var sink = radio.blocks.BenchmarkSink(f32).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

fn benchmark_complex_to_imag(allocator: std.mem.Allocator) !void {
    var source = radio.blocks.ZeroSource(std.math.Complex(f32)).init(1);
    var dut = radio.blocks.ComplexToImagBlock.init();
    var sink = radio.blocks.BenchmarkSink(f32).init(.{});

    var top = radio.Flowgraph.init(allocator, .{});
    defer top.deinit();
    try top.connect(&source.block, &dut.block);
    try top.connect(&dut.block, &sink.block);

    try benchmark_run(&top);
}

////////////////////////////////////////////////////////////////////////////////
// Benchmarks Table
////////////////////////////////////////////////////////////////////////////////

const BenchmarkSpec = struct {
    name: []const u8,
    func: *const fn (std.mem.Allocator) anyerror!void,
};

const BenchmarkSuite: []const BenchmarkSpec = &[_]BenchmarkSpec{
    .{ .name = "Five Back to Back FIR Filters (256 Real taps, Complex input)", .func = &benchmark_fir_filter_five_back_to_back },
    .{ .name = "Zero Source (Complex)", .func = &benchmark_zero_source_complex },
    .{ .name = "Zero Source (Real)", .func = &benchmark_zero_source_real },
    .{ .name = "Signal Source (Cosine)", .func = &benchmark_signal_source_cosine },
    .{ .name = "Signal Source (Square)", .func = &benchmark_signal_source_square },
    .{ .name = "FIR Filter (128 Complex taps, Complex input)", .func = benchmark_fir_filter_complex_taps_complex_input },
    .{ .name = "FIR Filter (128 Real taps, Complex input)", .func = benchmark_fir_filter_real_taps_complex_input },
    .{ .name = "FIR Filter (128 Real taps, Real input)", .func = benchmark_fir_filter_real_taps_real_input },
    .{ .name = "IIR Filter (5 ff 3 fb Real taps, Complex input)", .func = benchmark_iir_filter_real_taps_complex_input },
    .{ .name = "IIR Filter (5 ff 3 fb Real taps, Real input)", .func = benchmark_iir_filter_real_taps_real_input },
    .{ .name = "FM Deemphasis Filter", .func = benchmark_fm_deemphasis_filter },
    .{ .name = "Downsampler (M = 5, Complex)", .func = benchmark_downsampler_complex },
    .{ .name = "Downsampler (M = 5, Real)", .func = benchmark_downsampler_real },
    .{ .name = "Frequency Translator", .func = benchmark_frequency_translator },
    .{ .name = "Frequency Discriminator", .func = benchmark_frequency_discriminator },
    .{ .name = "Complex Magnitude", .func = benchmark_complex_magnitude },
    .{ .name = "Complex to Real", .func = benchmark_complex_to_real },
    .{ .name = "Complex to Imaginary", .func = benchmark_complex_to_imag },
};

////////////////////////////////////////////////////////////////////////////////
// Entry Point
////////////////////////////////////////////////////////////////////////////////

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const benchmark_filter: ?[]const u8 = if (args.len > 1) args[1] else null;

    for (BenchmarkSuite) |benchmark| {
        if (benchmark_filter != null and std.ascii.indexOfIgnoreCase(benchmark.name, benchmark_filter.?) == null) continue;

        std.debug.print("Running {s}...\n", .{benchmark.name});
        try benchmark.func(allocator);
        std.debug.print("\n", .{});
    }
}
