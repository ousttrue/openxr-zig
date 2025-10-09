const std = @import("std");
const xrgen = @import("generator/index.zig");

const XrGenerateStep = xrgen.XrGenerateStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const xr_xml_path: ?[]const u8 = b.option([]const u8, "registry", "Override the path to the OpenXR registry");
    const test_step = b.step("test", "Run all the tests");

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
        }),
    });
    b.installArtifact(generator_exe);

    // or they can skip all that, and just make sure to pass `.registry = "path/to/xr.xml"` to `b.dependency`,
    // and then obtain the module directly via `.module("openxr-zig")`.
    if (xr_xml_path) |path| {
        const generate_cmd = b.addRunArtifact(generator_exe);

        if (!std.fs.path.isAbsolute(path)) @panic("Make sure to assign an absolute path to the `registry` option (see: std.Build.pathFromRoot).\n");
        generate_cmd.addArg(path);

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
            .root_module = b.addModule("example", .{
                .root_source_file = b.path("examples/test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(example_exe);
        example_exe.linkLibC();
        example_exe.linkSystemLibrary("openxr_loader");

        // const example_registry = b.option([]const u8, "example-registry", "Override the path to the OpenXR registry used for the examples") orelse "examples/xr.xml";
        // const gen = XrGenerateStep.create(b, example_registry);
        example_exe.root_module.addImport("openxr", xr_zig_module);

        const example_run_cmd = b.addRunArtifact(example_exe);
        example_run_cmd.step.dependOn(b.getInstallStep());

        const example_run_step = b.step("run-example", "Run the example");
        example_run_step.dependOn(&example_run_cmd.step);
    }

    // remainder of the script is for examples/testing

    const test_target = b.addTest(.{
        .root_module = b.addModule("test", .{
            .root_source_file = b.path("generator/index.zig"),
            .target = target,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_target).step);
}
