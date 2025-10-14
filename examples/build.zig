const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.addModule("example", .{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);
    exe.linkLibC();

    // copy dll
    const dll = b.addInstallBinFile(
        openxr_loader.prefix.getDirectory().path(b, "bin/openxr_loader.dll"),
        "openxr_loader.dll",
    );
    b.getInstallStep().dependOn(&dll.step);

    // const xr_xml_path: ?[]const u8 = b.option([]const u8, "registry", "Override the path to the OpenXR registry");
    // const registry_path = if (xr_xml_path) |override_registry|
    //     override_registry
    // else
    //     "xr.xml";
    const registry_path = openxr_dep.path("specification/registry/xr.xml");
    const openxr = b.dependency("xr_zig", .{
        .registry = registry_path.getPath(b),
    }).module("openxr");
    exe.root_module.addImport("openxr", openxr);

    const example_run_cmd = b.addRunArtifact(exe);
    example_run_cmd.step.dependOn(b.getInstallStep());
    const example_run_step = b.step("run", "Run the example");
    example_run_step.dependOn(&example_run_cmd.step);
}
