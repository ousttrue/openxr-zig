const std = @import("std");

const xml = @import("xml.zig");
const IdRenderer = @import("IdRenderer.zig");

const EnumFieldMerger = @import("EnumFieldMerger.zig");
const Renderer = @import("Renderer.zig");
const loadXml = @import("registry_loader.zig").loadXml;

const Args = @import("Args.zig");

pub fn main() !void {
    const args = try Args.init(std.os.argv);

    var stderr_buf: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.detectLeaks();
    const xml_src = std.fs.cwd().readFileAlloc(
        allocator,
        args.xml_path,
        std.math.maxInt(usize),
    ) catch |err| {
        try stderr.interface.print(
            "Error: Failed to open input file '{s}' ({s})\n",
            .{ args.xml_path, @errorName(err) },
        );
        return;
    };
    defer allocator.free(xml_src);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parser = xml.Parser.init(arena.allocator(), xml_src);
    const doc = try parser.parse();

    var registry = try loadXml(arena.allocator(), doc.root);
    // std.log.debug("{f}", .{parsed});

    // gen.removePromotedExtensions();
    {
        var write_index: usize = 0;
        for (registry.extensions) |ext| {
            if (ext.promoted_to == .none) {
                registry.extensions[write_index] = ext;
                write_index += 1;
            }
        }
        registry.extensions.len = write_index;
    }

    // Solve `registry.declarations` according to `registry.extensions` and `registry.features`.
    var merger = EnumFieldMerger.init(arena.allocator(), &registry);
    try merger.merge();

    var renderer = try Renderer.init(arena.allocator(), &registry);
    defer renderer.deinit();
    try renderer.render();

    const out_dir = try std.fs.cwd().openDir(args.out_path, .{ .access_sub_paths = true });
    var it = renderer.moduleFileMap.iterator();
    while (it.next()) |entry| {
        const content = try formatZigSource(allocator, entry.value_ptr.*.items);
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
