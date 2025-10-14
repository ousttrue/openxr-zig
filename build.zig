const std = @import("std");

const OpenXrVersion = enum {
    @"1_0_26",
    @"1_0_27",
    @"1_0_34", // 1.0 last
    @"1_1_36", // 1.1 first
    @"1_1_52",
};

fn get_xml(
    b: *std.Build,
    maybe_xr_xml_path: ?std.Build.LazyPath,
    maybe_sdk_version: ?OpenXrVersion,
) ?std.Build.LazyPath {
    if (maybe_xr_xml_path) |xr_xml_path| {
        return xr_xml_path;
    }
    if (maybe_sdk_version) |sdk_version| {
        const openxr_dep = switch (sdk_version) {
            .@"1_0_26" => b.dependency("openxr_1_0_26", .{}),
            .@"1_0_27" => b.dependency("openxr_1_0_27", .{}),
            .@"1_0_34" => b.dependency("openxr_1_0_34", .{}),
            .@"1_1_36" => b.dependency("openxr_1_1_36", .{}),
            .@"1_1_52" => b.dependency("openxr_1_1_52", .{}),
        };
        return openxr_dep.path("specification/registry/xr.xml");
    }
    return null;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xr_xml_path = b.option(
        std.Build.LazyPath,
        "path",
        "xr.xml path.",
    );

    const use_openxr_xml = b.option(
        OpenXrVersion,
        "version",
        "xr.xml from specification/registry/xr.xml in openxr-sdk version",
    );

    // using the package manager, this artifact can be obtained by the user
    // through `b.dependency(<name in build.zig.zon>, .{}).artifact("openxr-zig-generator")`.
    // with that, the user need only `.addArg("path/to/xr.xml")`, and then obtain
    // a file source to the generated code with `.addOutputArg("xr.zig")`
    const generator_exe = b.addExecutable(.{
        .name = "openxr-zig-generator",
        .root_module = b.addModule("openxr-zig-generator", .{
            .root_source_file = b.path("generator/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(generator_exe);

    if (get_xml(b, xr_xml_path, use_openxr_xml)) |path| {
        const generate_cmd = b.addRunArtifact(generator_exe);
        generate_cmd.addFileArg(path);
        const xr_zig_dir = generate_cmd.addOutputDirectoryArg("xr");
        const xr_module = b.addModule("xr", .{
            .root_source_file = xr_zig_dir.path(b, "xr.zig"),
        });
        b.modules.put("openxr", xr_module) catch @panic("OOM");

        // Also install xr.zig, if passed.
        const xr_zig_install_step = b.addInstallDirectory(.{
            .source_dir = xr_zig_dir,
            .install_dir = .{ .prefix = void{} },
            .install_subdir = "src/xr",
        });
        // xr_zig_install_step.step.dependOn(&generate_cmd.step);
        b.getInstallStep().dependOn(&xr_zig_install_step.step);
    }

    const test_target = b.addTest(.{
        .root_module = b.addModule("test", .{
            .root_source_file = b.path("generator/test.zig"),
            .target = target,
        }),
    });
    b.installArtifact(test_target);
    const test_step = b.step("test", "Run all the tests");
    test_step.dependOn(&b.addRunArtifact(test_target).step);

    // const generated = b.addLibrary(.{
    //     .name = "generated",
    //     .root_module = b.addModule("generated", .{
    //         .root_source_file = b.path("zig-out/src/xr/xr.zig"),
    //         .target = target,
    //     }),
    // });
    // b.installArtifact(generated);
}
