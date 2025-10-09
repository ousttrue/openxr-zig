const std = @import("std");
const xml = @import("xml.zig");
const Generator = @import("openxr/generator.zig").Generator;
const parseXml = @import("openxr/parse.zig").parseXml;
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

    const doc = xml.parse(allocator, xml_src) catch |err| switch (err) {
        error.InvalidDocument,
        error.UnexpectedEof,
        error.UnexpectedCharacter,
        error.IllegalCharacter,
        error.InvalidEntity,
        error.InvalidName,
        error.InvalidStandaloneValue,
        error.NonMatchingClosingTag,
        error.UnclosedComment,
        error.UnclosedValue,
        => return error.InvalidXml,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer doc.deinit();

    var parsed = try parseXml(allocator, doc.root);
    defer parsed.deinit();

    var gen = Generator.init(parsed.arena.allocator(), parsed.registry) catch |err| switch (err) {
        error.InvalidXml,
        error.InvalidCharacter,
        error.Overflow,
        error.InvalidFeatureLevel,
        error.InvalidSyntax,
        error.InvalidTag,
        error.MissingTypeIdentifier,
        error.UnexpectedCharacter,
        error.UnexpectedEof,
        error.UnexpectedToken,
        error.InvalidRegistry,
        => return error.InvalidRegistry,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // defer gen.deinit();
    gen.removePromotedExtensions();
    try gen.mergeEnumFields();

    // var out_buffer = std.array_list.Managed(u8).init(allocator);
    // defer out_buffer.deinit();
    // var buf: [1024]u8 = undefined;
    // var adapter = out_buffer.writer().adaptToNewApi(&buf);
    // var writer = &adapter.new_interface;

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var writer = &out.writer;

    gen.render(writer) catch |err| switch (err) {
        error.InvalidApiConstant,
        error.InvalidConstantExpr,
        error.InvalidRegistry,
        error.UnexpectedCharacter,
        => return error.InvalidRegistry,
        else => |others| return others,
    };
    try writer.writeByte(0);
    try writer.flush();

    const slice = try out.toOwnedSlice();
    const src: [:0]u8 = @ptrCast(std.mem.sliceTo(slice, 0));
    defer allocator.free(src);

    // var tree = try std.zig.Ast.parse(allocator, src, .zig);
    // defer tree.deinit(allocator);
    // for (tree.errors) |e| {
    //     std.log.debug("{s}", .{@errorName(e)});
    // }
    // var formatted = std.Io.Writer.Allocating.init(allocator);
    // defer formatted.deinit();
    // try tree.render(allocator, &formatted.writer, .{});
    // if (std.fs.path.dirname(args.out_path)) |dir| {
    //     cwd.makePath(dir) catch |err| {
    //         try stderr.interface.print("Error: Failed to create output directory '{s}' ({s})\n", .{ dir, @errorName(err) });
    //         return;
    //     };
    // }

    cwd.writeFile(.{
        .sub_path = args.out_path,
        // .data = try formatted.toOwnedSlice(),
        .data = src,
    }) catch |err| {
        try stderr.interface.print(
            "Error: Failed to write to output file '{s}' ({s})\n",
            .{ args.out_path, @errorName(err) },
        );
        return;
    };
}
