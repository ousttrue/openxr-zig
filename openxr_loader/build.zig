const std = @import("std");
const zbk = @import("zbk");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    // const optimize = b.standardOptimizeOption(.{});

    const source = b.option(std.Build.LazyPath, "path", "OpenXR-SDK path") orelse {
        return error.no_openxr_path;
    };

    if (target.result.abi.isAndroid()) {
        // break :blk try zbk.cpp.cmake.build(b, .{
        //     .source = openxr_dep.path(""),
        //     .build_dir_name = "build-android",
        //     .ndk_path = ndk_path,
        //     .args = &.{"-DDYNAMIC_LOADER=ON"},
        // });
    } else {
        // const vcenv = try zbk.windows.VcEnv.init(b.allocator);
        const cmake_build = zbk.cpp.CMakeStep.create(b, .{
            .source = source.getPath(b),
            .build_dir_name = "build-win32",
            .use_vcenv = target.result.os.tag == .windows,
            .args = &.{"-DDYNAMIC_LOADER=ON"},
        });

        const install = b.addInstallDirectory(.{
            .source_dir = cmake_build.getInstallPrefix(),
            .install_dir = .{ .custom = "" },
            .install_subdir = "",
        });
        // const install = b.addInstallDirectory(.{
        //     .source_dir = cmake_build.prefix.getDirectory(),
        //     .install_dir = .prefix,
        //     .install_subdir = "",
        // });
        b.getInstallStep().dependOn(&install.step);

        const prefix = b.addNamedWriteFiles("prefix");
        _ = prefix.addCopyDirectory(cmake_build.getInstallPrefix(), "", .{});
        _ = prefix.addCopyFile(source.path(b, "specification/registry/xr.xml"), "xr.xml");
    }
}
