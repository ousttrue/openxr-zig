const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // or they can skip all that, and just make sure to pass `.registry = "path/to/xr.xml"` to `b.dependency`,
    // and then obtain the module directly via `.module("openxr-zig")`.
    const xr_xml_path: ?[]const u8 = b.option([]const u8, "registry", "Override the path to the OpenXR registry");
    if (xr_xml_path) |path| {
        const generate_cmd = b.addRunArtifact(generator_exe);
        generate_cmd.addArg(path);
        const xr_zig = generate_cmd.addOutputFileArg("xr.zig");
        const xr_module = b.addModule("xr", .{
            .root_source_file = xr_zig,
        });
        b.modules.put("openxr", xr_module) catch @panic("OOM");

        // Also install xr.zig, if passed.
        const xr_zig_install_step = b.addInstallFile(xr_zig, "src/xr.zig");
        b.getInstallStep().dependOn(&xr_zig_install_step.step);
    }

    const test_target = b.addTest(.{
        .root_module = b.addModule("test", .{
            .root_source_file = b.path("generator/main.zig"),
            .target = target,
        }),
    });
    const test_step = b.step("test", "Run all the tests");
    test_step.dependOn(&b.addRunArtifact(test_target).step);

    // const generated = b.addLibrary(.{
    //     .name = "generated",
    //     .root_module = b.addModule("generated", .{
    //         .root_source_file = b.path("zig-out/src/xr.zig"),
    //         .target = target,
    //     }),
    // });
    // b.installArtifact(generated);
}
