const std = @import("std");
const xml = @import("../xml/xml.zig");
const XmlElement = xml.XmlDocument.Element;
const XmlCTokenizer = @import("XmlCTokenizer.zig");
const c_types = @import("c_types.zig");
const Container = @import("Container.zig");
const Enum = @import("Enum.zig");
const ApiConstant = @import("ApiConstant.zig");

pub const Bitmask = struct {
    bits_enum: ?[]const u8,
};

pub const Handle = struct {
    parent: ?[]const u8, // XrInstance has no parent
    is_dispatchable: bool,
};

pub const Alias = struct {
    pub const Target = enum {
        other_command,
        other_type,
    };

    name: []const u8,
    target: Target,
};

pub const Foreign = struct {
    depends: []const u8, // Either a header or openxr_platform_defines
};

pub const DeclarationType = union(enum) {
    container: Container,
    enumeration: Enum,
    bitmask: Bitmask,
    handle: Handle,
    command: c_types.Command,
    alias: Alias,
    foreign: Foreign,
    typedef: c_types.TypeInfo,
    external,
};

name: []const u8,
decl_type: DeclarationType,

pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (this.decl_type) {
        .container => try writer.print("container: {s}", .{this.name}),
        .enumeration => try writer.print("enum: {s}", .{this.name}),
        .bitmask => try writer.print("bitmask: {s}", .{this.name}),
        .handle => try writer.print("handle: {s}", .{this.name}),
        .command => try writer.print("command: {s}", .{this.name}),
        .alias => try writer.print("alias: {s}", .{this.name}),
        .foreign => try writer.print("foreign: {s}", .{this.name}),
        .typedef => try writer.print("typedef: {s}", .{this.name}),
        .external => try writer.print("external: {s}", .{this.name}),
    }
}

pub fn parseDeclarations(allocator: std.mem.Allocator, root: *XmlElement) ![]@This() {
    const types_elem = root.findChildByTag("types") orelse return error.InvalidRegistry;
    var commands_elems_it = root.findChildrenByTag("commands");

    var decl_upper_bound = types_elem.children.len;
    while (commands_elems_it.next()) |commands_elem| {
        decl_upper_bound += commands_elem.children.len;
    }

    const decls = try allocator.alloc(@This(), decl_upper_bound);

    var count: usize = 0;
    {
        var it = types_elem.findChildrenByTag("type");
        while (it.next()) |ty| {
            if (parseType(allocator, ty)) |maybe_decl| {
                if (maybe_decl) |decl| {
                    decls[count] = decl;
                    count += 1;
                }
            } else |e| {
                std.log.err("{f}", .{ty});
                return e;
            }
        }
    }
    {
        var it = root.findChildrenByTag("enums");
        while (it.next()) |enums| {
            const name = enums.getAttribute("name") orelse return error.InvalidRegistry;
            if (std.mem.eql(u8, name, ApiConstant.api_constants_name)) {
                continue;
            }
            decls[count] = .{
                .name = name,
                .decl_type = .{ .enumeration = try Enum.parse(allocator, enums) },
            };
            count += 1;
        }
    }

    commands_elems_it = root.findChildrenByTag("commands");
    while (commands_elems_it.next()) |commands_elem| {
        var it = commands_elem.findChildrenByTag("command");
        while (it.next()) |elem| {
            if (elem.getAttribute("alias")) |alias| {
                const name = elem.getAttribute("name") orelse return error.InvalidRegistry;
                decls[count] = .{
                    .name = name,
                    .decl_type = .{ .alias = .{ .name = alias, .target = .other_command } },
                };
            } else {
                const command = try c_types.Command.parse(allocator, elem);
                decls[count] = .{
                    .name = command.name,
                    .decl_type = .{ .command = command },
                };
            }
            count += 1;
        }
    }
    return decls[0..count];
}

fn parseType(allocator: std.mem.Allocator, ty: *XmlElement) !?@This() {
    if (ty.getAttribute("category")) |category| {
        // std.log.debug("{f}", .{ty});
        if (std.mem.eql(u8, category, "bitmask")) {
            return try parseBitmaskType(ty);
        } else if (std.mem.eql(u8, category, "handle")) {
            return try parseHandleType(ty);
        } else if (std.mem.eql(u8, category, "basetype")) {
            return try parseBaseType(allocator, ty);
        } else if (std.mem.eql(u8, category, "struct")) {
            return try parseContainer(allocator, ty, false);
        } else if (std.mem.eql(u8, category, "union")) {
            return try parseContainer(allocator, ty, true);
        } else if (std.mem.eql(u8, category, "funcpointer")) {
            return try parseFuncPointer(allocator, ty);
        } else if (std.mem.eql(u8, category, "enum")) {
            if (try parseEnumAlias(ty)) |decl| {
                return decl;
            }
        }
    } else {
        return try parseForeigntype(ty);
    }
    return null;
}

fn parseBitmaskType(ty: *XmlElement) !@This() {
    if (ty.getAttribute("name")) |name| {
        const alias = ty.getAttribute("alias") orelse return error.InvalidRegistry;
        return @This(){
            .name = name,
            .decl_type = .{ .alias = .{ .name = alias, .target = .other_type } },
        };
    } else {
        return @This(){
            .name = ty.getCharData("name") orelse return error.InvalidRegistry,
            .decl_type = .{ .bitmask = .{ .bits_enum = ty.getAttribute("bitvalues") } },
        };
    }
}

fn parseHandleType(ty: *XmlElement) !@This() {
    // Parent is not handled in case of an alias
    if (ty.getAttribute("name")) |name| {
        const alias = ty.getAttribute("alias") orelse return error.InvalidRegistry;
        return @This(){
            .name = name,
            .decl_type = .{ .alias = .{ .name = alias, .target = .other_type } },
        };
    } else {
        const name = ty.getCharData("name") orelse return error.InvalidRegistry;
        const handle_type = ty.getCharData("type") orelse return error.InvalidRegistry;
        const dispatchable = std.mem.eql(u8, handle_type, "XR_DEFINE_HANDLE");
        if (!dispatchable and !std.mem.eql(u8, handle_type, "XR_DEFINE_NON_DISPATCHABLE_HANDLE")) {
            return error.InvalidRegistry;
        }

        return @This(){
            .name = name,
            .decl_type = .{
                .handle = .{
                    .parent = ty.getAttribute("parent"),
                    .is_dispatchable = dispatchable,
                },
            },
        };
    }
}

fn parseBaseType(allocator: std.mem.Allocator, ty: *XmlElement) !@This() {
    const name = ty.getCharData("name") orelse return error.InvalidRegistry;
    if (ty.getCharData("type")) |_| {
        var tok = XmlCTokenizer.init(ty);
        return try tok.parseTypedef(allocator, false);
    } else {
        // Either ANativeWindow, AHardwareBuffer or CAMetalLayer. The latter has a lot of
        // macros, which is why this part is not built into the xml/c parser.
        return @This(){
            .name = name,
            .decl_type = .{ .foreign = .{ .depends = &.{} } },
        };
    }
}

fn parseContainer(allocator: std.mem.Allocator, ty: *XmlElement, is_union: bool) !@This() {
    const name = ty.getAttribute("name") orelse return error.NoName;

    if (ty.getAttribute("alias")) |alias| {
        return @This(){
            .name = name,
            .decl_type = .{ .alias = .{ .name = alias, .target = .other_type } },
        };
    }

    return @This(){
        .name = name,
        .decl_type = .{
            .container = try Container.parse(allocator, ty, is_union),
        },
    };
}

fn parseFuncPointer(allocator: std.mem.Allocator, ty: *XmlElement) !@This() {
    var xctok = XmlCTokenizer.init(ty);
    return try xctok.parseTypedef(allocator, true);
}

fn parseEnumAlias(elem: *XmlElement) !?@This() {
    if (elem.getAttribute("alias")) |alias| {
        const name = elem.getAttribute("name") orelse return error.InvalidRegistry;
        return @This(){
            .name = name,
            .decl_type = .{ .alias = .{ .name = alias, .target = .other_type } },
        };
    }

    return null;
}

fn parseForeigntype(ty: *XmlElement) !@This() {
    const name = ty.getAttribute("name") orelse return error.InvalidRegistry;
    const depends = ty.getAttribute("requires") orelse if (std.mem.eql(u8, name, "int"))
        "openxr_platform_defines" // for some reason, int doesn't depend on xr_platform (but the other c types do)
    else
        return error.InvalidRegistry;

    return @This(){
        .name = name,
        .decl_type = .{ .foreign = .{ .depends = depends } },
    };
}
