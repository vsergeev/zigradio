const std = @import("std");

const Example = struct {
    name: []const u8,
    path: []const u8,
};

const examples = [_]Example{
    .{ .name = "example-rtlsdr_wbfm_mono", .path = "examples/rtlsdr_wbfm_mono.zig" },
    .{ .name = "example-play_tone", .path = "examples/play_tone.zig" },
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create radio module
    const radio_module = b.addModule("radio", .{ .root_source_file = b.path("src/radio.zig") });
    radio_module.addImport("radio", radio_module);

    // Build examples
    const examples_step = b.step("examples", "Build examples");
    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = b.path(example.path),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("radio", radio_module);
        exe.linkLibC();

        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    // Run unit tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/radio.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.linkLibC();
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run framework tests");
    test_step.dependOn(&run_tests.step);

    // Run benchmark suite
    const benchmark_step = b.step("benchmark", "Run benchmark suite");
    const benchmark_suite = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("benchmarks/benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    benchmark_suite.root_module.addImport("radio", radio_module);
    benchmark_suite.linkLibC();
    const run_benchmark_suite = b.addRunArtifact(benchmark_suite);
    if (b.args) |args| run_benchmark_suite.addArgs(args);
    benchmark_step.dependOn(&run_benchmark_suite.step);

    // Generate test vectors
    const generate_step = b.step("generate", "Generate test vectors");
    const generate_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "generate.py" });
    generate_step.dependOn(&generate_cmd.step);
}
