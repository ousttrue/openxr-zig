const std = @import("std");
const xml = @import("xml/xml.zig");
const XmlDocument = xml.XmlDocument;
const Element = XmlDocument.Element;
const EnumFieldMerger = @import("EnumFieldMerger.zig");
const XmlCTokenizer = @import("XmlCTokenizer.zig");
pub const ApiConstant = @import("ApiConstant.zig");
const FeatureLevel = @import("FeatureLevel.zig");
pub const Enum = @import("Enum.zig");
const Extension = @import("Extension.zig");
pub const Require = @import("Require.zig");
const Feature = @import("Feature.zig");
const c_types = @import("c_types.zig");
const Container = @import("Container.zig");

pub const Declaration = struct {
    name: []const u8,
    decl_type: DeclarationType,
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

pub const Alias = struct {
    pub const Target = enum {
        other_command,
        other_type,
    };

    name: []const u8,
    target: Target,
};

pub const Tag = struct {
    name: []const u8,
    author: []const u8,

    fn parse(allocator: std.mem.Allocator, root: *Element) ![]@This() {
        var tags_elem = root.findChildByTag("tags") orelse return error.InvalidRegistry;
        const tags = try allocator.alloc(@This(), tags_elem.children.len);

        var i: usize = 0;
        var it = tags_elem.findChildrenByTag("tag");
        while (it.next()) |tag| {
            tags[i] = .{
                .name = tag.getAttribute("name") orelse return error.InvalidRegistry,
                .author = tag.getAttribute("author") orelse return error.InvalidRegistry,
            };

            i += 1;
        }

        return tags[0..i];
    }
};

pub const Bitmask = struct {
    bits_enum: ?[]const u8,
};

pub const Handle = struct {
    parent: ?[]const u8, // XrInstance has no parent
    is_dispatchable: bool,
};

pub const Foreign = struct {
    depends: []const u8, // Either a header or openxr_platform_defines
};

decls: []Declaration,
api_constants: []ApiConstant,
tags: []Tag,
features: []Feature,
extensions: []Extension,

pub fn getConstant(this: @This(), name: []const u8) ?ApiConstant {
    for (this.api_constants) |c| {
        if (std.mem.eql(u8, name, c.name)) {
            return c;
        }
    }
    return null;
}

pub fn load(allocator: std.mem.Allocator, xml_path: []const u8) !@This() {
    const xml_src = std.fs.cwd().readFileAlloc(
        allocator,
        xml_path,
        std.math.maxInt(usize),
    ) catch |err| {
        std.log.err(
            "Error: Failed to open input file '{s}' ({s})",
            .{ xml_path, @errorName(err) },
        );
        return error.fail_open_xml_path;
    };
    defer allocator.free(xml_src);

    const doc = try xml.parse(allocator, xml_src);

    var registry = @This(){
        .decls = try parseDeclarations(allocator, doc.root),
        .api_constants = try ApiConstant.parse(allocator, doc.root),
        .tags = try Tag.parse(allocator, doc.root),
        .features = try Feature.parse(allocator, doc.root),
        .extensions = try Extension.parse(allocator, doc.root),
    };

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
    var merger = EnumFieldMerger.init(allocator, &registry);
    try merger.merge();

    return registry;
}

fn parseDeclarations(allocator: std.mem.Allocator, root: *Element) ![]Declaration {
    const types_elem = root.findChildByTag("types") orelse return error.InvalidRegistry;
    const commands_elem = root.findChildByTag("commands") orelse return error.InvalidRegistry;

    const decl_upper_bound = types_elem.children.len + commands_elem.children.len;
    const decls = try allocator.alloc(Declaration, decl_upper_bound);

    var count: usize = 0;
    {
        var it = types_elem.findChildrenByTag("type");
        while (it.next()) |ty| {
            if (try parseType(allocator, ty)) |decl| {
                decls[count] = decl;
                count += 1;
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
    {
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

fn parseType(allocator: std.mem.Allocator, ty: *Element) !?Declaration {
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

fn parseForeigntype(ty: *Element) !Declaration {
    const name = ty.getAttribute("name") orelse return error.InvalidRegistry;
    const depends = ty.getAttribute("requires") orelse if (std.mem.eql(u8, name, "int"))
        "openxr_platform_defines" // for some reason, int doesn't depend on xr_platform (but the other c types do)
    else
        return error.InvalidRegistry;

    return Declaration{
        .name = name,
        .decl_type = .{ .foreign = .{ .depends = depends } },
    };
}

fn parseBitmaskType(ty: *Element) !Declaration {
    if (ty.getAttribute("name")) |name| {
        const alias = ty.getAttribute("alias") orelse return error.InvalidRegistry;
        return Declaration{
            .name = name,
            .decl_type = .{ .alias = .{ .name = alias, .target = .other_type } },
        };
    } else {
        return Declaration{
            .name = ty.getCharData("name") orelse return error.InvalidRegistry,
            .decl_type = .{ .bitmask = .{ .bits_enum = ty.getAttribute("bitvalues") } },
        };
    }
}

fn parseHandleType(ty: *Element) !Declaration {
    // Parent is not handled in case of an alias
    if (ty.getAttribute("name")) |name| {
        const alias = ty.getAttribute("alias") orelse return error.InvalidRegistry;
        return Declaration{
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

        return Declaration{
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

fn parseBaseType(allocator: std.mem.Allocator, ty: *Element) !Declaration {
    const name = ty.getCharData("name") orelse return error.InvalidRegistry;
    if (ty.getCharData("type")) |_| {
        var tok = XmlCTokenizer.init(ty);
        return try tok.parseTypedef(allocator, false);
    } else {
        // Either ANativeWindow, AHardwareBuffer or CAMetalLayer. The latter has a lot of
        // macros, which is why this part is not built into the xml/c parser.
        return Declaration{
            .name = name,
            .decl_type = .{ .foreign = .{ .depends = &.{} } },
        };
    }
}

fn parseContainer(allocator: std.mem.Allocator, ty: *Element, is_union: bool) !Declaration {
    const name = ty.getAttribute("name") orelse return error.InvalidRegistry;

    if (ty.getAttribute("alias")) |alias| {
        return Declaration{
            .name = name,
            .decl_type = .{ .alias = .{ .name = alias, .target = .other_type } },
        };
    }

    var members = try allocator.alloc(Container.Field, ty.children.len);

    var i: usize = 0;
    var it = ty.findChildrenByTag("member");
    var maybe_stype: ?[]const u8 = null;
    while (it.next()) |member| {
        var xctok = XmlCTokenizer.init(member);
        members[i] = try xctok.parseMember(allocator, false);
        if (std.mem.eql(u8, members[i].name, "type")) {
            if (member.getAttribute("values")) |stype| {
                maybe_stype = stype;
            }
        }

        if (member.getAttribute("optional")) |optionals| {
            var optional_it = std.mem.splitScalar(u8, optionals, ',');
            if (optional_it.next()) |first_optional| {
                members[i].is_optional = std.mem.eql(u8, first_optional, "true");
            } else {
                // Optional is empty, probably incorrect.
                return error.InvalidRegistry;
            }
        }
        i += 1;
    }

    members = members[0..i];

    var maybe_extends: ?[][]const u8 = null;
    if (ty.getAttribute("structextends")) |extends| {
        const n_structs = std.mem.count(u8, extends, ",") + 1;
        maybe_extends = try allocator.alloc([]const u8, n_structs);
        var struct_extends = std.mem.splitScalar(u8, extends, ',');
        var j: usize = 0;
        while (struct_extends.next()) |struct_extend| {
            maybe_extends.?[j] = struct_extend;
            j += 1;
        }
    }

    it = ty.findChildrenByTag("member");
    for (members) |*member| {
        const member_elem = it.next().?;
        try Container.parsePointerMeta(members, &member.field_type, member_elem);

        // next isn't always properly marked as optional, so just manually override it,
        if (std.mem.eql(u8, member.name, "next")) {
            member.field_type.pointer.is_optional = true;
        }
    }

    return Declaration{
        .name = name,
        .decl_type = .{
            .container = .{
                .stype = maybe_stype,
                .fields = members,
                .is_union = is_union,
                .extends = maybe_extends,
            },
        },
    };
}

fn parseFuncPointer(allocator: std.mem.Allocator, ty: *Element) !Declaration {
    var xctok = XmlCTokenizer.init(ty);
    return try xctok.parseTypedef(allocator, true);
}

fn parseEnumAlias(elem: *Element) !?Declaration {
    if (elem.getAttribute("alias")) |alias| {
        const name = elem.getAttribute("name") orelse return error.InvalidRegistry;
        return Declaration{
            .name = name,
            .decl_type = .{ .alias = .{ .name = alias, .target = .other_type } },
        };
    }

    return null;
}
