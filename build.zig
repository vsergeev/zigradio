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

// Adapted from private std.build.Builder.execPkgConfigList()
// FIXME not exactly portable or stable
fn getPlatformPackages(self: *std.build.Builder) ![]const []const u8 {
    var code: u8 = undefined;
    const stdout = try self.execAllowFail(&[_][]const u8{ "pkg-config", "--list-all" }, &code, .Ignore);
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

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    // Create platform options with packages list
    const platform_options = b.addOptions();
    platform_options.addOption([]const []const u8, "packages", try getPlatformPackages(b));

    const examples_step = b.step("examples", "Build examples");
    for (examples) |example| {
        const exe = b.addExecutable(example.name, example.path);
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.addPackage(.{
            .name = "radio",
            .source = .{ .path = "src/radio.zig" },
            .dependencies = &.{platform_options.getPackage("platform_options")},
        });
        exe.linkLibC();
        for (example.libs) |libname| exe.linkSystemLibrary(libname);

        examples_step.dependOn(&b.addInstallArtifact(exe).step);
    }

    const tests = b.addTest("src/radio.zig");
    tests.addPackagePath("radio", "src/radio.zig");
    tests.addOptions("platform_options", platform_options);
    tests.setBuildMode(mode);

    const test_step = b.step("test", "Run framework tests");
    test_step.dependOn(&tests.step);

    const generate_step = b.step("generate", "Generate test vectors");
    const generate_cmd = b.addSystemCommand(&[_][]const u8{ "python3", "generate.py" });
    generate_step.dependOn(&generate_cmd.step);
}
