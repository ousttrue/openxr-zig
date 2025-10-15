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
    std.log.debug("delcs: {}", .{registry.decls.len});
    var counter = struct {
        container: usize = 0,
        enumeration: usize = 0,
        bitmask: usize = 0,
        handle: usize = 0,
        command: usize = 0,
        alias: usize = 0,
        foreign: usize = 0,
        typedef: usize = 0,
        external: usize = 0,
    }{};
    for (registry.decls) |decl| {
        switch (decl.decl_type) {
            .container => counter.container += 1,
            .enumeration => counter.enumeration += 1,
            .bitmask => counter.bitmask += 1,
            .handle => counter.handle += 1,
            .command => counter.command += 1,
            .alias => counter.alias += 1,
            .foreign => counter.foreign += 1,
            .typedef => counter.typedef += 1,
            .external => counter.external += 1,
        }
    }
    std.log.debug("  container => {}", .{counter.container});
    std.log.debug("  enumeration => {}", .{counter.enumeration});
    std.log.debug("  bitmask => {}", .{counter.bitmask});
    std.log.debug("  handle => {}", .{counter.handle});
    std.log.debug("  command => {}", .{counter.command});
    std.log.debug("  alias => {}", .{counter.alias});
    std.log.debug("  foreign => {}", .{counter.foreign});
    std.log.debug("  typedef => {}", .{counter.typedef});
    std.log.debug("  external => {}", .{counter.external});

    var renderer = try Renderer.init(allocator, &registry);
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

fn formatZigSource(allocator: std.mem.Allocator, src: [:0]u8) ![]const u8 {
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
            // std.log.debug("mkdir: {s}", .{dir});
            try cwd.makePath(dir);
        };
    }
    try cwd.writeFile(.{
        .sub_path = out_path,
        .data = content,
    });
}
