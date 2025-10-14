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

    const openxr_dep = b.dependency("openxr_1_0_26", .{});
    const openxr_loader_dep = b.dependency("openxr_loader", .{
        .path = openxr_dep.path(""),
    });
    const openxr_loader_prefix = openxr_loader_dep.namedWriteFiles("prefix");
    // link
    exe.addLibraryPath(openxr_loader_prefix.getDirectory().path(b, "lib"));
    exe.linkSystemLibrary("openxr_loader");
    // copy dll
    const dll = b.addInstallBinFile(
        openxr_loader_prefix.getDirectory().path(b, "bin/openxr_loader.dll"),
        "openxr_loader.dll",
    );
    b.getInstallStep().dependOn(&dll.step);

    const openxr = b.dependency("xr_zig", .{
        .path = openxr_dep.path("specification/registry/xr.xml"),
    }).module("openxr");
    exe.root_module.addImport("openxr", openxr);

    const example_run_cmd = b.addRunArtifact(exe);
    example_run_cmd.step.dependOn(b.getInstallStep());
    const example_run_step = b.step("run", "Run the example");
    example_run_step.dependOn(&example_run_cmd.step);
}
