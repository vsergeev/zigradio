const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("radio", "src/radio.zig");
    lib.setTarget(target);
    lib.setBuildMode(mode);
    lib.linkLibC();
    lib.install();

    const examples_step = b.step("examples", "Build examples");
    var examples_dir = try std.fs.cwd().openIterableDir("examples", .{});
    var examples_it = examples_dir.iterate();
    while (try examples_it.next()) |entry| {
        const example_name = try std.mem.concat(b.allocator, u8, &[_][]const u8{ "example-", entry.name[0..std.mem.indexOfScalar(u8, entry.name, '.').?] });
        const example_path = b.pathJoin(&.{ "examples", entry.name });

        const exe = b.addExecutable(example_name, example_path);
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.addPackage(.{
            .name = "radio",
            .source = .{ .path = "src/radio.zig" },
        });
        exe.linkLibrary(lib);
        exe.linkSystemLibrary("pulse-simple");
        exe.linkSystemLibrary("pulse");
        exe.linkSystemLibrary("rtlsdr");

        examples_step.dependOn(&b.addInstallArtifact(exe).step);
    }

    const tests = b.addTest("src/radio.zig");
    tests.addPackagePath("radio", "src/radio.zig");
    tests.setBuildMode(mode);

    const test_step = b.step("test", "Run framework tests");
    test_step.dependOn(&tests.step);
}
