const std = @import("std");
const zbk = @import("zbk");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    // const optimize = b.standardOptimizeOption(.{});

    const openxr_dep = b.dependency("openxr", .{});

    if (target.result.abi.isAndroid()) {
        // break :blk try zbk.cpp.cmake.build(b, .{
        //     .source = openxr_dep.path(""),
        //     .build_dir_name = "build-android",
        //     .ndk_path = ndk_path,
        //     .args = &.{"-DDYNAMIC_LOADER=ON"},
        // });
    } else {
        const vcenv = try zbk.windows.VcEnv.init(b.allocator);
        const cmake_build = try zbk.cpp.cmake.build(b, .{
            .source = openxr_dep.path(""),
            .build_dir_name = "build-win32",
            .envmap = vcenv.envmap,
            .args = &.{"-DDYNAMIC_LOADER=ON"},
        });
        const install = b.addInstallDirectory(.{
            .source_dir = cmake_build.prefix.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "",
        });
        b.getInstallStep().dependOn(&install.step);

        const prefix = b.addNamedWriteFiles("prefix");
        _ = prefix.addCopyDirectory(cmake_build.prefix.getDirectory(), "", .{});
        _ = prefix.addCopyFile(openxr_dep.path("specification/registry/xr.xml"), "xr.xml");
    }
}
