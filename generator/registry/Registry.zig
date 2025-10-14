const std = @import("std");
const xml = @import("xml/xml.zig");
const XmlElement = xml.XmlDocument.Element;
const XmlCTokenizer = @import("XmlCTokenizer.zig");
const ApiConstant = @import("ApiConstant.zig");
const Enum = @import("Enum.zig");
const Extension = @import("Extension.zig");
const Feature = @import("Feature.zig");
const c_types = @import("c_types.zig");
const Container = @import("Container.zig");
const Declaration = @import("Declaration.zig");
const Require = @import("Require.zig");

const Registry = @This();

const EnumFieldMerger = struct {
    arena: std.mem.Allocator,
    registry: *Registry,
    enum_extensions: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Enum.Field)),
    field_set: std.StringArrayHashMapUnmanaged(void),

    pub fn init(arena: std.mem.Allocator, registry: *Registry) @This() {
        return .{
            .arena = arena,
            .registry = registry,
            .enum_extensions = .{},
            .field_set = .{},
        };
    }

    fn putEnumExtension(self: *@This(), enum_name: []const u8, field: Enum.Field) !void {
        const res = try self.enum_extensions.getOrPut(self.arena, enum_name);
        if (!res.found_existing) {
            res.value_ptr.* = std.ArrayListUnmanaged(Enum.Field){};
        }

        try res.value_ptr.append(self.arena, field);
    }

    fn addRequires(self: *@This(), reqs: []const Require) !void {
        for (reqs) |req| {
            for (req.extends) |enum_ext| {
                try self.putEnumExtension(enum_ext.extends, enum_ext.field);
            }
        }
    }

    fn mergeEnumFields(self: *@This(), name: []const u8, base_enum: *Enum) !void {
        // If there are no extensions for this enum, assume its valid.
        const extensions = self.enum_extensions.get(name) orelse return;

        self.field_set.clearRetainingCapacity();

        const n_fields_upper_bound = base_enum.fields.len + extensions.items.len;
        const new_fields = try self.arena.alloc(Enum.Field, n_fields_upper_bound);
        var i: usize = 0;

        for (base_enum.fields) |field| {
            const res = try self.field_set.getOrPut(self.arena, field.name);
            if (!res.found_existing) {
                new_fields[i] = field;
                i += 1;
            }
        }

        // Assume that if a field name clobbers, the value is the same
        for (extensions.items) |field| {
            const res = try self.field_set.getOrPut(self.arena, field.name);
            if (!res.found_existing) {
                new_fields[i] = field;
                i += 1;
            }
        }

        // Existing base_enum.fields was allocated by `self.arena`, so
        // it gets cleaned up whenever that is deinited.
        base_enum.fields = new_fields[0..i];
    }

    pub fn merge(self: *@This()) !void {
        for (self.registry.features) |feature| {
            try self.addRequires(feature.requires);
        }

        for (self.registry.extensions) |ext| {
            try self.addRequires(ext.requires);
        }

        // Merge all the enum fields.
        // Assume that all keys of enum_extensions appear in `self.registry.decls`
        for (self.registry.decls) |*decl| {
            if (decl.decl_type == .enumeration) {
                try self.mergeEnumFields(decl.name, &decl.decl_type.enumeration);
            }
        }
    }
};

pub const Tag = struct {
    name: []const u8,
    author: []const u8,

    fn parse(allocator: std.mem.Allocator, root: *XmlElement) ![]@This() {
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

fn parseDeclarations(allocator: std.mem.Allocator, root: *XmlElement) ![]Declaration {
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

fn parseType(allocator: std.mem.Allocator, ty: *XmlElement) !?Declaration {
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

fn parseForeigntype(ty: *XmlElement) !Declaration {
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

fn parseBitmaskType(ty: *XmlElement) !Declaration {
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

fn parseHandleType(ty: *XmlElement) !Declaration {
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

fn parseBaseType(allocator: std.mem.Allocator, ty: *XmlElement) !Declaration {
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

fn parseContainer(allocator: std.mem.Allocator, ty: *XmlElement, is_union: bool) !Declaration {
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

fn parseFuncPointer(allocator: std.mem.Allocator, ty: *XmlElement) !Declaration {
    var xctok = XmlCTokenizer.init(ty);
    return try xctok.parseTypedef(allocator, true);
}

fn parseEnumAlias(elem: *XmlElement) !?Declaration {
    if (elem.getAttribute("alias")) |alias| {
        const name = elem.getAttribute("name") orelse return error.InvalidRegistry;
        return Declaration{
            .name = name,
            .decl_type = .{ .alias = .{ .name = alias, .target = .other_type } },
        };
    }

    return null;
}
