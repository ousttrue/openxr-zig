const std = @import("std");

const xml = @import("xml.zig");
const IdRenderer = @import("IdRenderer.zig");

const EnumFieldMerger = @import("openxr/EnumFieldMerger.zig");
const renderRegistry = @import("openxr/render.zig").render;
const loadXml = @import("openxr/registry_loader.zig").loadXml;

const Args = @import("Args.zig");

pub fn main() !void {
    const args = try Args.init(std.os.argv);

    var stderr_buf: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.detectLeaks();
    const cwd = std.fs.cwd();
    const xml_src = cwd.readFileAlloc(
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

    // var arena = ArenaAllocator.init(backing_allocator);
    // errdefer arena.deinit();
    // const allocator = arena.allocator();

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
    // try gen.mergeEnumFields();
    var merger = EnumFieldMerger.init(arena.allocator(), &registry);
    try merger.merge();

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var writer = &out.writer;
    // try gen.render(&out.writer);
    // pub fn render(self: *Generator, writer: *std.io.Writer) !void {

    var id_renderer = IdRenderer.init(arena.allocator(), registry.tags);
    try renderRegistry(writer, arena.allocator(), &registry, &id_renderer);
    try writer.writeByte(0);
    try writer.flush();
    // }

    const slice = try out.toOwnedSlice();
    const src: [:0]u8 = @ptrCast(std.mem.sliceTo(slice, 0));
    defer allocator.free(src);

    var tree = try std.zig.Ast.parse(allocator, src, .zig);
    defer tree.deinit(allocator);
    for (tree.errors) |e| {
        std.log.debug("{s}", .{@tagName(e.tag)});
    }
    var formatted = std.Io.Writer.Allocating.init(allocator);
    defer formatted.deinit();
    try tree.render(allocator, &formatted.writer, .{});
    if (std.fs.path.dirname(args.out_path)) |dir| {
        cwd.makePath(dir) catch |err| {
            try stderr.interface.print("Error: Failed to create output directory '{s}' ({s})\n", .{ dir, @errorName(err) });
            return;
        };
    }

    const zig_src = try formatted.toOwnedSlice();
    defer allocator.free(zig_src);
    cwd.writeFile(.{
        .sub_path = args.out_path,
        .data = zig_src,
        // .data = src,
    }) catch |err| {
        try stderr.interface.print(
            "Error: Failed to write to output file '{s}' ({s})\n",
            .{ args.out_path, @errorName(err) },
        );
        return;
    };
}
