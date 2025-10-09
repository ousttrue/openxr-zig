const std = @import("std");
const usage = "Usage: {s} [-h|--help] <spec xml path> <output zig source>\n";

xml_path: []const u8,
out_path: []const u8,

pub fn init(args: [][*:0]u8) !@This() {
    const prog_name: []const u8 = std.mem.sliceTo(args[0], 0);

    var maybe_xml_path: ?[]const u8 = null;
    var maybe_out_path: ?[]const u8 = null;

    for (args, 0..) |_arg, i| {
        if (i == 0) {
            continue;
        }
        const arg: []const u8 = std.mem.sliceTo(_arg, 0);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            @setEvalBranchQuota(2000);
            std.debug.print(
                \\Utility to generate a Zig binding from the OpenXR XML API registry.
                \\
                \\The most recent OpenXR XML API registry can be obtained from
                \\https://github.com/KhronosGroup/OpenXR-Docs/blob/master/xml/xr.xml,
                \\and the most recent LunarG OpenXR SDK version can be found at
                \\$OPENXR_SDK/x86_64/share/openxr/registry/xr.xml.
                \\
                \\
            ++ usage,
                .{prog_name},
            );
            return error.help;
        } else if (maybe_xml_path == null) {
            maybe_xml_path = arg;
        } else if (maybe_out_path == null) {
            maybe_out_path = arg;
        } else {
            std.debug.print("Error: Superficial argument '{s}'\n", .{arg});
            return error.invalid_arg;
        }
    }

    const xml_path = maybe_xml_path orelse {
        std.debug.print("Error: Missing required argument <spec xml path>\n" ++ usage, .{prog_name});
        return error.no_xml_path;
    };

    const out_path = maybe_out_path orelse {
        std.debug.print("Error: Missing required argument <output zig source>\n" ++ usage, .{prog_name});
        return error.no_out_path;
    };

    return .{
        .xml_path = xml_path,
        .out_path = out_path,
    };
}
