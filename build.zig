const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("XevApp", .{
        .root_source_file = b.path("XevApp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // vaxis mod
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis.module("vaxis");
    lib_mod.addImport("vaxis", vaxis_mod);

    const libxev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    const xev_mod = libxev.module("xev");
    lib_mod.addImport("xev", xev_mod);

    const exe = b.addExecutable(.{
        .name = "example",
        .root_source_file = b.path("example.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("XevApp", lib_mod);
    exe.root_module.addImport("vaxis", vaxis_mod);
    exe.root_module.addImport("xev", xev_mod);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("XevApp.zig"),
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
