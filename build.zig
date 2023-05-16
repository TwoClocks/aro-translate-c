const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "aro-translate-c",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // arocc has copies of some files from the zig
    // repro. including type.zig. Reslove someday
    const aro_zig_module = b.createModule(.{
        .source_file = .{ .path = "../arocc/deps/zig/lib.zig" },
    });

    const aro_module = b.addModule("aro", .{
        .source_file = std.build.FileSource.relative("../arocc/src/lib.zig"),
        .dependencies = &.{.{
            .name = "zig",
            .module = aro_zig_module,
        }},
    });
    exe.addModule("aro", aro_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
