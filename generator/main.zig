const std = @import("std");
const Args = @import("Args.zig");
const Registry = @import("registry/Registry.zig");
const Renderer = @import("Renderer.zig");

pub fn main() !void {
    const args = try Args.init(std.os.argv);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const registry = try Registry.load(arena.allocator(), args.xml_path);
    const version = registry.getConstant("XR_CURRENT_API_VERSION") orelse unreachable;
    std.log.debug("{f}", .{version});
    for (registry.features) |feature| {
        std.log.debug("{f}", .{feature});
    }
    std.log.debug("extensins: {}", .{registry.extensions.len});
    // for (registry.extensions) |extension| {
    //     std.log.debug("{f}", .{extension});
    // }
    for (registry.features) |feature| {
        std.log.debug("[feature: {s}]", .{feature.name});
        //     for (feature.requires) |req| {
        //         for (req.commands) |command| {
        //             std.log.debug("{s}", .{command});
        //         }
        //     }
    }

    var renderer = try Renderer.init(arena.allocator(), &registry);
    defer renderer.deinit();
    try renderer.render();

    const out_dir = try std.fs.cwd().openDir(args.out_path, .{ .access_sub_paths = true });
    var it = renderer.moduleFileMap.iterator();
    while (it.next()) |entry| {
        const content = try formatZigSource(allocator, entry.value_ptr.*);
        defer allocator.free(content);
        writeFile(out_dir, entry.key_ptr.*, content) catch |e| {
            std.log.err("  error => {s}", .{@errorName(e)});
            @panic("writeFile");
        };
    }
}

fn formatZigSource(allocator: std.mem.Allocator, content: []u8) ![]const u8 {
    const src: [:0]u8 = @ptrCast(std.mem.sliceTo(content, 0));
    var tree = try std.zig.Ast.parse(allocator, src, .zig);
    defer tree.deinit(allocator);
    for (tree.errors) |e| {
        std.log.debug("{s}", .{@tagName(e.tag)});
    }
    var formatted = std.Io.Writer.Allocating.init(allocator);
    defer formatted.deinit();
    try tree.render(allocator, &formatted.writer, .{});
    const zig_src = try formatted.toOwnedSlice();
    return zig_src;
}

fn writeFile(cwd: std.fs.Dir, out_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(out_path)) |dir| {
        cwd.access(dir, .{}) catch {
            std.log.debug("mkdir: {s}", .{dir});
            try cwd.makePath(dir);
        };
    }
    try cwd.writeFile(.{
        .sub_path = out_path,
        .data = content,
    });
}
