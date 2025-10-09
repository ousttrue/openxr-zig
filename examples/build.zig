const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const example_exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.addModule("example", .{
            .root_source_file = b.path("test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(example_exe);
    example_exe.linkLibC();
    example_exe.linkSystemLibrary("openxr_loader");

    const xr_xml_path: ?[]const u8 = b.option([]const u8, "registry", "Override the path to the OpenXR registry");
    const registry_path = if (xr_xml_path) |override_registry|
        override_registry
    else
        b.path("xr.xml").getPath(b);
    const openxr = b.dependency("xr_zig", .{
        .registry = registry_path,
    }).module("openxr");
    example_exe.root_module.addImport("openxr", openxr);

    const example_run_cmd = b.addRunArtifact(example_exe);
    example_run_cmd.step.dependOn(b.getInstallStep());
    const example_run_step = b.step("run-example", "Run the example");
    example_run_step.dependOn(&example_run_cmd.step);
}
