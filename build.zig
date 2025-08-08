const std = @import("std");
const xrgen = @import("generator/index.zig");

const LOADER_SRC = .{
    "src/loader/android_utilities.cpp",
    "src/loader/api_layer_interface.cpp",
    "src/loader/loader_core.cpp",
    // "src/loader/loader_init_data.cpp",
    "src/loader/loader_instance.cpp",
    "src/loader/loader_logger.cpp",
    "src/loader/loader_logger_recorders.cpp",
    "src/loader/manifest_file.cpp",
    "src/loader/runtime_interface.cpp",
    "src/common/object_info.cpp",
    "src/common/filesystem_utils.cpp",
    "src/xr_generated_dispatch_table.c",
    // "src/xr_generated_dispatch_table_core.c",
    "src/external/jsoncpp/src/lib_json/json_reader.cpp",
    "src/external/jsoncpp/src/lib_json/json_value.cpp",
    "src/external/jsoncpp/src/lib_json/json_writer.cpp",
};
const LOADER_FLAGS = .{
    "-DXR_OS_WINDOWS",
    "-DXR_USE_PLATFORM_WIN32",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // const xr_xml_path: ?[]const u8 = b.option([]const u8, "registry", "Override the path to the OpenXR registry");
    const test_step = b.step("test", "Run all the tests");

    // using the package manager, this artifact can be obtained by the user
    // through `b.dependency(<name in build.zig.zon>, .{}).artifact("openxr-zig-generator")`.
    // with that, the user need only `.addArg("path/to/xr.xml")`, and then obtain
    // a file source to the generated code with `.addOutputArg("xr.zig")`
    const generator_exe = b.addExecutable(.{
        .name = "openxr-zig-generator",
        .root_source_file = b.path("generator/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // b.installArtifact(generator_exe);

    const openxr_dep = b.dependency("openxr1027", .{});
    const xr_xml = openxr_dep.path("specification/registry/xr.xml");

    // or they can skip all that, and just make sure to pass `.registry = "path/to/xr.xml"` to `b.dependency`,
    // and then obtain the module directly via `.module("openxr-zig")`.
    const generate_cmd = b.addRunArtifact(generator_exe);

    generate_cmd.addFileArg(xr_xml);

    const xr_zig = generate_cmd.addOutputFileArg("xr.zig");
    const xr_zig_module = b.addModule("openxr-zig", .{
        .root_source_file = xr_zig,
    });

    // Also install xr.zig, if passed.

    const xr_zig_install_step = b.addInstallFile(xr_zig, "src/xr.zig");
    b.getInstallStep().dependOn(&xr_zig_install_step.step);

    // example

    const example_exe = b.addExecutable(.{
        .name = "example",
        .root_source_file = b.path("examples/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(example_exe);
    example_exe.linkLibC();

    // example_exe.linkSystemLibrary("openxr_loader");
    //
    // build openxr_loader from source
    //
    example_exe.linkLibCpp();
    example_exe.addCSourceFiles(.{
        .root = openxr_dep.path(""),
        .files = &LOADER_SRC,
        .flags = &LOADER_FLAGS,
    });
    example_exe.addIncludePath(openxr_dep.path("include"));
    example_exe.addIncludePath(openxr_dep.path("src/common"));
    example_exe.addIncludePath(openxr_dep.path("src"));
    example_exe.addIncludePath(openxr_dep.path("src/external/jsoncpp/include"));

    example_exe.root_module.addImport("openxr", xr_zig_module);

    const example_run_cmd = b.addRunArtifact(example_exe);
    example_run_cmd.step.dependOn(b.getInstallStep());

    const example_run_step = b.step("run-example", "Run the example");
    example_run_step.dependOn(&example_run_cmd.step);

    // remainder of the script is for examples/testing
    const test_target = b.addTest(.{
        .root_source_file = b.path("generator/index.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(test_target).step);
}
