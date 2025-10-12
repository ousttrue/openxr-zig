const std = @import("std");
const zbk = @import("zbk");

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

    // build openxr_loader
    const openxr_dep = b.dependency("openxr", .{});
    const openxr_loader = if (target.result.abi.isAndroid()) {
        // break :blk try zbk.cpp.cmake.build(b, .{
        //     .source = openxr_dep.path(""),
        //     .build_dir_name = "build-android",
        //     .ndk_path = ndk_path,
        //     .args = &.{"-DDYNAMIC_LOADER=ON"},
        // });
        unreachable;
    } else blk: {
        const vcenv = try zbk.windows.VcEnv.init(b.allocator);
        break :blk try zbk.cpp.cmake.build(b, .{
            .source = openxr_dep.path(""),
            .build_dir_name = "build-win32",
            .envmap = vcenv.envmap,
            .args = &.{"-DDYNAMIC_LOADER=ON"},
        });
    };
    exe.addLibraryPath(openxr_loader.prefix.getDirectory().path(b, "lib"));
    exe.linkSystemLibrary("openxr_loader");

    const xr_xml_path: ?[]const u8 = b.option([]const u8, "registry", "Override the path to the OpenXR registry");
    const registry_path = if (xr_xml_path) |override_registry|
        override_registry
    else
        b.path("xr.xml").getPath(b);
    const openxr = b.dependency("xr_zig", .{
        .registry = registry_path,
    }).module("openxr");
    exe.root_module.addImport("openxr", openxr);

    const example_run_cmd = b.addRunArtifact(exe);
    example_run_cmd.step.dependOn(b.getInstallStep());
    const example_run_step = b.step("run-example", "Run the example");
    example_run_step.dependOn(&example_run_cmd.step);
}
