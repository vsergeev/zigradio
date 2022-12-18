const std = @import("std");

const Example = struct {
    name: []const u8,
    path: []const u8,
};

pub fn build(b: *std.build.Builder) void {
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

    // FIXME discover
    const examples = [_]Example{
        .{ .name = "example-rtlsdr_wbfm_mono", .path = "examples/rtlsdr_wbfm_mono.zig" },
        .{ .name = "example-play_tone", .path = "examples/play_tone.zig" },
    };

    for (examples) |example| {
        const exe = b.addExecutable(example.name, example.path);
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
        exe.install();
    }

    const tests = b.addTest("src/radio.zig");
    tests.addPackagePath("radio", "src/radio.zig");
    tests.setBuildMode(mode);

    const test_step = b.step("test", "Run framework tests");
    test_step.dependOn(&tests.step);
}
