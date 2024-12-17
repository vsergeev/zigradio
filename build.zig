const std = @import("std");

const Example = struct {
    name: []const u8,
    path: []const u8,
    libs: []const []const u8,
};

const examples = [_]Example{
    .{ .name = "example-rtlsdr_wbfm_mono", .path = "examples/rtlsdr_wbfm_mono.zig", .libs = &.{ "pulse-simple", "pulse", "rtlsdr" } },
    .{ .name = "example-play_tone", .path = "examples/play_tone.zig", .libs = &.{ "pulse-simple", "pulse" } },
};

// Adapted from private std.Build.execPkgConfigList()
// FIXME not exactly portable or stable
fn getPlatformPackages(self: *std.Build) ![]const []const u8 {
    var code: u8 = undefined;
    const stdout = try self.runAllowFail(&[_][]const u8{ "pkg-config", "--list-all" }, &code, .Ignore);
    var list = std.ArrayList([]const u8).init(self.allocator);
    errdefer list.deinit();
    var line_it = std.mem.tokenize(u8, stdout, "\r\n");
    while (line_it.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        var tok_it = std.mem.tokenize(u8, line, " \t");
        try list.append(tok_it.next() orelse return error.PkgConfigInvalidOutput);
    }
    return list.toOwnedSlice();
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create platform options with packages list
    const platform_options = b.addOptions();
    platform_options.addOption([]const []const u8, "packages", try getPlatformPackages(b));

    // Create platform options module
    const platform_options_module = platform_options.createModule();

    // Create radio module
    const radio_module = b.addModule("radio", .{
        .root_source_file = b.path("src/radio.zig"),
        .imports = &.{
            .{ .name = "platform_options", .module = platform_options_module },
        },
    });
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
        for (example.libs) |libname| exe.linkSystemLibrary(libname);

        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    // Run unit tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/radio.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run framework tests");
    test_step.dependOn(&run_tests.step);

    // Generate test vectors
    const generate_step = b.step("generate", "Generate test vectors");
    const generate_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "generate.py" });
    generate_step.dependOn(&generate_cmd.step);
}
