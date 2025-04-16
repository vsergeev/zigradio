const std = @import("std");

const Example = struct {
    name: []const u8,
    path: []const u8,
};

fn discoverExamples(allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayList(Example) {
    var examples = std.ArrayList(Example).init(allocator);

    var examples_dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer examples_dir.close();

    var examples_it = examples_dir.iterate();
    while (try examples_it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            const name = try std.mem.concat(allocator, u8, &[_][]const u8{ "example-", entry.name[0 .. entry.name.len - 4] });
            const path = try std.fs.path.join(allocator, &[_][]const u8{ "examples", entry.name });
            try examples.append(.{ .name = name, .path = path });
        }
    }

    return examples;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create radio module
    const radio_module = b.addModule("radio", .{ .root_source_file = b.path("src/radio.zig") });

    // Discover examples
    const examples = try discoverExamples(b.allocator, b.path("examples").getPath(b));

    // Build examples
    const examples_step = b.step("examples", "Build examples");
    for (examples.items) |example| {
        const example_exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = b.path(example.path),
            .target = target,
            .optimize = .ReleaseFast,
        });
        example_exe.root_module.addImport("radio", radio_module);
        example_exe.linkLibC();
        const install_example = b.addInstallArtifact(example_exe, .{});

        examples_step.dependOn(&install_example.step);
    }

    // Run unit tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/radio.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.linkLibC();
    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;
    const test_step = b.step("test", "Run framework tests");
    test_step.dependOn(&run_tests.step);

    // Run benchmark suite
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
    const benchmark_step = b.step("benchmark", "Run benchmark suite");
    benchmark_step.dependOn(&run_benchmark_suite.step);

    // Generate test vectors
    const generate_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "generate.py" });
    const generate_step = b.step("generate", "Generate test vectors");
    generate_step.dependOn(&generate_cmd.step);
}
