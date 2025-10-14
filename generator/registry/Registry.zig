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

pub const Declaration = struct {
    name: []const u8,
    decl_type: DeclarationType,
};

pub const DeclarationType = union(enum) {
    container: Container,
    enumeration: Enum,
    bitmask: Bitmask,
    handle: Handle,
    command: Command,
    alias: Alias,
    foreign: Foreign,
    typedef: TypeInfo,
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

pub const TypeInfo = union(enum) {
    name: []const u8,
    command_ptr: Command,
    pointer: Pointer,
    array: Array,
};

pub const Container = struct {
    pub const Field = struct {
        name: []const u8,
        field_type: TypeInfo,
        bits: ?usize,
        is_buffer_len: bool,
        is_optional: bool,
    };

    stype: ?[]const u8,
    extends: ?[]const []const u8,
    fields: []Field,
    is_union: bool,
};

pub const Bitmask = struct {
    bits_enum: ?[]const u8,
};

pub const Handle = struct {
    parent: ?[]const u8, // XrInstance has no parent
    is_dispatchable: bool,
};

pub const Command = struct {
    pub const Param = struct {
        name: []const u8,
        param_type: TypeInfo,
        is_buffer_len: bool,
    };

    name: []const u8,
    params: []Param,
    return_type: *TypeInfo,
    success_codes: []const []const u8,
    error_codes: []const []const u8,

    pub fn parse(allocator: std.mem.Allocator, elem: *Element) !@This() {
        const proto = elem.findChildByTag("proto") orelse return error.InvalidRegistry;
        var proto_xctok = XmlCTokenizer.init(proto);
        const command_decl = try proto_xctok.parseParamOrProto(allocator, false);

        var params = try allocator.alloc(@This().Param, elem.children.len);

        var i: usize = 0;
        var it = elem.findChildrenByTag("param");
        while (it.next()) |param| {
            var xctok = XmlCTokenizer.init(param);
            const decl = try xctok.parseParamOrProto(allocator, false);
            params[i] = .{
                .name = decl.name,
                .param_type = decl.decl_type.typedef,
                .is_buffer_len = false,
            };
            i += 1;
        }

        const return_type = try allocator.create(TypeInfo);
        return_type.* = command_decl.decl_type.typedef;

        var success_codes: [][]const u8 = if (elem.getAttribute("successcodes")) |codes|
            try splitCommaAlloc(allocator, codes)
        else
            &[_][]const u8{};

        var error_codes: [][]const u8 = if (elem.getAttribute("errorcodes")) |codes|
            try splitCommaAlloc(allocator, codes)
        else
            &[_][]const u8{};

        for (success_codes, 0..) |code, session_i| {
            if (std.mem.eql(u8, code, "XR_SESSION_LOSS_PENDING")) {
                var move_i = session_i + 1;
                while (move_i < success_codes.len) : (move_i += 1) {
                    success_codes[move_i - 1] = success_codes[move_i];
                }
                success_codes = success_codes[0..success_codes.len];
                success_codes.len = success_codes.len - 1;

                const old_error_codes = error_codes;
                error_codes = try allocator.alloc([]const u8, error_codes.len + 1);
                std.mem.copyForwards([]const u8, error_codes, old_error_codes);
                error_codes[error_codes.len - 1] = code;
                allocator.free(old_error_codes);
                break;
            }
        }

        params = params[0..i];

        it = elem.findChildrenByTag("param");
        for (params) |*param| {
            const param_elem = it.next().?;
            try parsePointerMeta(.{ .command = params }, &param.param_type, param_elem);
        }

        return .{
            .name = command_decl.name,
            .params = params,
            .return_type = return_type,
            .success_codes = success_codes,
            .error_codes = error_codes,
        };
    }
};

pub const Pointer = struct {
    pub const PointerSize = union(enum) {
        one,
        many, // The length is given by some complex expression, possibly involving another field
        other_field: []const u8, // The length is given by some other field or parameter
        zero_terminated,
    };

    is_const: bool,
    is_optional: bool,
    size: PointerSize,
    child: *TypeInfo,
};

pub const Array = struct {
    pub const Size = union(enum) {
        int: usize,
        alias: []const u8, // Field size is given by an api constant
    };

    size: Size,
    child: *TypeInfo,
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
                const command = try Command.parse(allocator, elem);
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
        try parsePointerMeta(.{ .container = members }, &member.field_type, member_elem);

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

// For some reason, the DeclarationType cannot be passed to lenToPointer, as
// that causes the Zig compiler to generate invalid code for the function. Using a
// dedicated enum fixes the issue...
const Fields = union(enum) {
    command: []Command.Param,
    container: []Container.Field,
};

// returns .{ size, nullable }
fn lenToPointer(fields: Fields, len: []const u8) std.meta.Tuple(&.{ Pointer.PointerSize, bool }) {
    switch (fields) {
        .command => |params| {
            for (params) |*param| {
                if (std.mem.eql(u8, param.name, len)) {
                    param.is_buffer_len = true;
                    return .{ .{ .other_field = param.name }, false };
                }
            }
        },
        .container => |members| {
            for (members) |*member| {
                if (std.mem.eql(u8, member.name, len)) {
                    member.is_buffer_len = true;
                    return .{ .{ .other_field = member.name }, member.is_optional };
                }
            }
        },
    }

    if (std.mem.eql(u8, len, "null-terminated")) {
        return .{ .zero_terminated, false };
    } else {
        return .{ .many, false };
    }
}

fn parsePointerMeta(fields: Fields, type_info: *TypeInfo, elem: *Element) !void {
    if (elem.getAttribute("len")) |lens| {
        var it = std.mem.splitScalar(u8, lens, ',');
        var current_type_info = type_info;
        while (current_type_info.* == .pointer) {
            // TODO: Check altlen
            const size = if (it.next()) |len_str| blk: {
                const size_optional = lenToPointer(fields, len_str);
                current_type_info.pointer.is_optional = size_optional[1];
                break :blk size_optional[0];
            } else .many;
            current_type_info.pointer.size = size;
            current_type_info = current_type_info.pointer.child;
        }

        if (it.next()) |_| {
            // There are more elements in the `len` attribute than there are pointers
            // Something probably went wrong
            std.log.err("len: {s}", .{lens});
            return error.InvalidRegistry;
        }
    }

    if (elem.getAttribute("optional")) |optionals| {
        var it = std.mem.splitScalar(u8, optionals, ',');
        var current_type_info = type_info;
        while (current_type_info.* == .pointer) {
            if (it.next()) |current_optional| {
                current_type_info.pointer.is_optional = std.mem.eql(u8, current_optional, "true");
            } else {
                current_type_info.pointer.is_optional = true;
                // There is no information for this pointer, probably incorrect.
                // return error.InvalidRegistry;
            }

            current_type_info = current_type_info.pointer.child;
        }
    } else if (std.mem.eql(u8, elem.getCharData("name") orelse "", "next")) {
        type_info.pointer.is_optional = true;
    }
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

fn splitCommaAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var n_codes: usize = 1;
    for (text) |c| {
        if (c == ',') n_codes += 1;
    }

    const codes = try allocator.alloc([]const u8, n_codes);
    var it = std.mem.splitScalar(u8, text, ',');
    for (codes) |*code| {
        code.* = it.next().?;
    }

    return codes;
}
