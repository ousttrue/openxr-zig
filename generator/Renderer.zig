const std = @import("std");
const Registry = @import("registry/Registry.zig");
const IdRenderer = @import("IdRenderer.zig");
const CTokenizer = @import("registry/CTokenizer.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const CaseStyle = IdRenderer.CaseStyle;
const Container = @import("registry/Container.zig");
const c_types = @import("registry/c_types.zig");

const builtin_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "void", @typeName(void) },
    .{ "char", @typeName(u8) },
    .{ "float", @typeName(f32) },
    .{ "double", @typeName(f64) },
    .{ "uint8_t", @typeName(u8) },
    .{ "uint16_t", @typeName(u16) },
    .{ "uint32_t", @typeName(u32) },
    .{ "uint64_t", @typeName(u64) },
    .{ "int16_t", @typeName(i16) },
    .{ "int32_t", @typeName(i32) },
    .{ "int64_t", @typeName(i64) },
    .{ "size_t", @typeName(usize) },
    .{ "wchar_t", @typeName(u16) },
    .{ "int", @typeName(c_int) },
});

const foreign_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Display", "opaque {}" },
    .{ "VisualID", @typeName(c_uint) },
    .{ "Window", @typeName(c_ulong) },
    .{ "xcb_glx_fbconfig_t", "opaque {}" },
    .{ "xcb_glx_drawable_t", "opaque {}" },
    .{ "xcb_glx_context_t", "opaque {}" },
    .{ "xcb_connection_t", "opaque {}" },
    .{ "xcb_visualid_t", @typeName(u32) },
    .{ "xcb_window_t", @typeName(u32) },
    .{ "VkAllocationCallbacks", "@import(\"vulkan\").AllocationCallbacks" },
    .{ "VkDevice", "@import(\"vulkan\").Device" },
    .{ "VkDeviceCreateInfo", "@import(\"vulkan\").DeviceCreateInfo" },
    .{ "VkFormat", "@import(\"vulkan\").Format" },
    .{ "VkImage", "@import(\"vulkan\").Image" },
    .{ "VkInstance", "@import(\"vulkan\").Instance" },
    .{ "VkInstanceCreateInfo", "@import(\"vulkan\").InstanceCreateInfo" },
    .{ "VkPhysicalDevice", "@import(\"vulkan\").PhysicalDevice" },
    .{ "VkResult", "@import(\"vulkan\").Result" },
    .{ "PFN_vkGetInstanceProcAddr", "@import(\"vulkan\").PfnGetInstanceProcAddr" },
});

const initialized_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "XrVector2f", "0" },
    .{ "XrVector3f", "0" },
    .{ "XrVector4f", "0" },
    .{ "XrColor4f", "0" },
    .{ "XrQuaternionf", "0" },
    .{ "XrPosef", ".{}" },
    .{ "XrOffset2Df", "0" },
    .{ "XrExtent2Df", "0" },
    .{ "XrRect2Df", ".{}" },
    .{ "XrOffset2Di", "0" },
    .{ "XrExtent2Di", "0" },
    .{ "XrRect2Di", ".{}" },
});

fn eqlIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
    if (lhs.len != rhs.len) {
        return false;
    }

    for (lhs, rhs) |l, r| {
        if (std.ascii.toLower(l) != std.ascii.toLower(r)) {
            return false;
        }
    }

    return true;
}

pub fn trimXrNamespace(id: []const u8) []const u8 {
    const prefixes = [_][]const u8{ "XR_", "xr", "Xr", "PFN_xr" };
    for (prefixes) |prefix| {
        if (mem.startsWith(u8, id, prefix)) {
            return id[prefix.len..];
        }
    }

    return id;
}

const Self = @This();

const BitflagName = struct {
    /// Name without FlagBits, so XrSurfaceTransformFlagBitsKHR
    /// becomes XrSurfaceTransform
    base_name: []const u8,

    /// Optional tag of the flag
    tag: ?[]const u8,
};

const ParamType = enum {
    in_pointer,
    out_pointer,
    in_out_pointer,
    bitflags,
    mut_buffer_len,
    buffer_len,
    other,
};

const ReturnValue = struct {
    name: []const u8,
    return_value_type: c_types.TypeInfo,
    origin: enum {
        parameter,
        inner_return_value,
    },
};

const CommandDispatchType = enum {
    base,
    instance,
};

allocator: Allocator,
registry: *const Registry,
id_renderer: IdRenderer,
declarations_by_name: std.StringHashMap(*const Registry.DeclarationType),
structure_types: std.StringHashMap(void),
moduleFileMap: std.StringHashMap([:0]u8),

pub fn init(allocator: Allocator, registry: *const Registry) !Self {
    var declarations_by_name = std.StringHashMap(*const Registry.DeclarationType).init(allocator);
    errdefer declarations_by_name.deinit();

    for (registry.decls) |*decl| {
        const result = try declarations_by_name.getOrPut(decl.name);
        if (result.found_existing) {
            return error.InvalidRegistry;
        }

        result.value_ptr.* = &decl.decl_type;
    }

    const xr_structure_type_decl = declarations_by_name.get("XrStructureType") orelse return error.InvalidRegistry;
    const xr_structure_type = switch (xr_structure_type_decl.*) {
        .enumeration => |e| e,
        else => return error.InvalidRegistry,
    };
    var structure_types = std.StringHashMap(void).init(allocator);
    errdefer structure_types.deinit();

    for (xr_structure_type.fields) |field| {
        try structure_types.put(field.name, {});
    }

    return Self{
        .allocator = allocator,
        .registry = registry,
        .id_renderer = .init(allocator, registry.tags),
        .declarations_by_name = declarations_by_name,
        .structure_types = structure_types,
        .moduleFileMap = .init(allocator),
    };
}

pub fn deinit(this: *Self) void {
    var it = this.moduleFileMap.iterator();
    while (it.next()) |entry| {
        this.allocator.free(entry.value_ptr.*);
    }
    this.moduleFileMap.deinit();
    this.declarations_by_name.deinit();
}

fn writeIdentifier(_: *Self, writer: *std.Io.Writer, id: []const u8) !void {
    try IdRenderer.writeIdentifier(writer, id);
}

fn writeIdentifierWithCase(this: *Self, writer: *std.Io.Writer, case: CaseStyle, id: []const u8) !void {
    try this.id_renderer.renderWithCase(writer, case, id);
}

fn writeIdentifierFmt(this: *Self, writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) IdRenderer.Error!void {
    try this.id_renderer.renderFmt(writer, fmt, args);
}

fn extractEnumFieldName(this: *Self, enum_name: []const u8, field_name: []const u8) ![]const u8 {
    const adjusted_enum_name = if (mem.eql(u8, enum_name, "XrStructureType"))
        "XrType"
    else
        this.id_renderer.stripAuthorTag(enum_name);
    var enum_it = IdRenderer.SegmentIterator.init(adjusted_enum_name);
    var field_it = IdRenderer.SegmentIterator.init(field_name);

    while (true) {
        const rest = field_it.rest();
        const enum_segment = enum_it.next() orelse return rest;
        const field_segment = field_it.next() orelse return error.InvalidRegistry;

        if (!eqlIgnoreCase(enum_segment, field_segment)) {
            return rest;
        }
    }
}

fn extractBitflagName(this: *Self, name: []const u8) ?BitflagName {
    const tag = this.id_renderer.getAuthorTag(name);
    const base_name = if (tag) |tag_name| name[0 .. name.len - tag_name.len] else name;

    if (!mem.endsWith(u8, base_name, "FlagBits")) {
        return null;
    }

    return BitflagName{
        .base_name = base_name[0 .. base_name.len - "FlagBits".len],
        .tag = tag,
    };
}

fn isFlags(this: *Self, name: []const u8) bool {
    const tag = this.id_renderer.getAuthorTag(name);
    const base_name = if (tag) |tag_name| name[0 .. name.len - tag_name.len] else name;

    return mem.endsWith(u8, base_name, "Flags64");
}

fn resolveDeclaration(this: *Self, name: []const u8) ?Registry.DeclarationType {
    const decl = this.declarations_by_name.get(name) orelse return null;
    return this.resolveAlias(decl.*) catch return null;
}

fn resolveAlias(this: *Self, start_decl: Registry.DeclarationType) !Registry.DeclarationType {
    var decl = start_decl;
    while (true) {
        const name = switch (decl) {
            .alias => |alias| alias.name,
            else => return decl,
        };

        const decl_ptr = this.declarations_by_name.get(name) orelse return error.InvalidRegistry;
        decl = decl_ptr.*;
    }
}

fn isInOutPointer(this: *Self, ptr: Registry.Pointer) !bool {
    if (ptr.child.* != .name) {
        return false;
    }

    const decl = this.resolveDeclaration(ptr.child.name) orelse return error.InvalidRegistry;
    if (decl != .container) {
        return false;
    }

    const container = decl.container;
    if (container.is_union) {
        return false;
    }

    for (container.fields) |field| {
        if (mem.eql(u8, field.name, "next")) {
            return true;
        }
    }

    return false;
}

fn classifyParam(this: *Self, param: Registry.Command.Param) !ParamType {
    switch (param.param_type) {
        .pointer => |ptr| {
            if (param.is_buffer_len) {
                if (ptr.is_const or ptr.is_optional) {
                    return error.InvalidRegistry;
                }

                return .mut_buffer_len;
            }

            if (ptr.child.* == .name) {
                const child_name = ptr.child.name;
                if (mem.eql(u8, child_name, "void")) {
                    return .other;
                } else if (builtin_types.get(child_name) == null and trimXrNamespace(child_name).ptr == child_name.ptr) {
                    return .other; // External type
                }
            }

            if (ptr.size == .one and !ptr.is_optional) {
                // Sometimes, a mutable pointer to a struct is taken, even though
                // OpenXR expects this struct to be initialized. This is particularly the case
                // for getting structs which include next chains.
                if (ptr.is_const) {
                    return .in_pointer;
                } else if (try this.isInOutPointer(ptr)) {
                    return .in_out_pointer;
                } else {
                    return .out_pointer;
                }
            }
        },
        .name => |name| {
            if (this.extractBitflagName(name) != null or this.isFlags(name)) {
                return .bitflags;
            }
        },
        else => {},
    }

    if (param.is_buffer_len) {
        return .buffer_len;
    }

    return .other;
}

fn classifyCommandDispatch(name: []const u8, command: Registry.Command) CommandDispatchType {
    const override_functions = std.StaticStringMap(CommandDispatchType).initComptime(.{
        .{ "xrGetInstanceProcAddr", .base },
        .{ "xrCreateInstance", .base },
        .{ "xrEnumerateApiLayerProperties", .base },
        .{ "xrEnumerateInstanceExtensionProperties", .base },
    });

    if (override_functions.get(name)) |dispatch_type| {
        return dispatch_type;
    }

    return switch (command.params[0].param_type) {
        .name => .instance,
        else => return .base,
    };
}

fn renderApiConstant(this: *Self, writer: *std.Io.Writer, api_constant: Registry.ApiConstant) !void {
    try writer.writeAll("pub const ");
    try this.renderName(writer, api_constant.name);
    try writer.writeAll(" = ");

    switch (api_constant.value) {
        .expr => |expr| try this.renderApiConstantExpr(writer, expr),
        .version => |version| {
            try writer.writeAll("makeVersion(");
            for (version, 0..) |part, i| {
                if (i != 0) {
                    try writer.writeAll(", ");
                }
                try this.renderApiConstantExpr(writer, part);
            }
            try writer.writeAll(")");
        },
    }

    try writer.writeAll(";\n");
}

fn renderApiConstantExpr(this: *Self, writer: *std.Io.Writer, expr: []const u8) !void {
    const adjusted_expr = if (expr.len > 2 and expr[0] == '(' and expr[expr.len - 1] == ')')
        expr[1 .. expr.len - 1]
    else
        expr;

    var tokenizer = CTokenizer{ .source = adjusted_expr };
    var peeked: ?CTokenizer.Token = null;
    while (true) {
        const tok = peeked orelse (try tokenizer.next()) orelse break;
        peeked = null;

        switch (tok.kind) {
            .lparen, .rparen, .tilde, .minus => {
                try writer.writeAll(tok.text);
                continue;
            },
            .id => {
                try this.renderName(writer, tok.text);
                continue;
            },
            .int => {},
            else => return error.InvalidApiConstant,
        }

        const suffix = (try tokenizer.next()) orelse {
            try writer.writeAll(tok.text);
            break;
        };

        switch (suffix.kind) {
            .id => {
                if (mem.eql(u8, suffix.text, "ULL")) {
                    try writer.print("@as(u64, {s})", .{tok.text});
                } else if (mem.eql(u8, suffix.text, "U")) {
                    try writer.print("@as(u32, {s})", .{tok.text});
                } else {
                    return error.InvalidApiConstant;
                }
            },
            .dot => {
                const decimal = (try tokenizer.next()) orelse return error.InvalidConstantExpr;
                try writer.print("@as(f32, {s}.{s})", .{ tok.text, decimal.text });

                const f = (try tokenizer.next()) orelse return error.InvalidConstantExpr;
                if (f.kind != .id or !mem.eql(u8, f.text, "f")) {
                    return error.InvalidApiConstant;
                }
            },
            else => {
                try writer.writeAll(tok.text);
                peeked = suffix;
            },
        }
    }
}

fn renderTypeInfo(this: *Self, writer: *std.Io.Writer, type_info: c_types.TypeInfo) IdRenderer.Error!void {
    switch (type_info) {
        .name => |name| try this.renderName(writer, name),
        .command_ptr => |command_ptr| try this.renderCommandPtr(writer, command_ptr, true),
        .pointer => |pointer| try this.renderPointer(writer, pointer),
        .array => |array| try this.renderArray(writer, array),
    }
}

fn renderName(this: *Self, writer: *std.Io.Writer, name: []const u8) IdRenderer.Error!void {
    if (builtin_types.get(name)) |zig_name| {
        try writer.writeAll(zig_name);
        return;
    } else if (this.extractBitflagName(name)) |bitflag_name| {
        try this.writeIdentifierFmt(writer, "{s}Flags{s}", .{
            trimXrNamespace(bitflag_name.base_name),
            @as([]const u8, if (bitflag_name.tag) |tag| tag else ""),
        });
        return;
    } else if (mem.startsWith(u8, name, "xr")) {
        // Function type, always render with the exact same text for linking purposes.
        try this.writeIdentifier(writer, name);
        return;
    } else if (mem.startsWith(u8, name, "Xr")) {
        // Type, strip namespace and write, as they are alreay in title case.
        try this.writeIdentifier(writer, name[2..]);
        return;
    } else if (mem.startsWith(u8, name, "PFN_xr")) {
        // Function pointer type, strip off the PFN_xr part and replace it with Pfn. Note that
        // this function is only called to render the typedeffed function pointers like xrVoidFunction
        try this.writeIdentifierFmt(writer, "Pfn{s}", .{name[6..]});
        return;
    } else if (mem.startsWith(u8, name, "XR_")) {
        // Constants
        try this.writeIdentifier(writer, name[3..]);
        return;
    }

    try this.writeIdentifier(writer, name);
}

fn renderCommandPtr(
    this: *Self,
    writer: *std.Io.Writer,
    command_ptr: c_types.Command,
    optional: bool,
) IdRenderer.Error!void {
    if (optional) {
        try writer.writeByte('?');
    }
    try writer.writeAll("*const fn(");
    for (command_ptr.params) |param| {
        try this.writeIdentifierWithCase(writer, .snake, param.name);
        try writer.writeAll(": ");

        blk: {
            if (param.param_type == .name) {
                if (this.extractBitflagName(param.param_type.name)) |bitflag_name| {
                    try this.writeIdentifierFmt(writer, "{s}Flags{s}", .{
                        trimXrNamespace(bitflag_name.base_name),
                        @as([]const u8, if (bitflag_name.tag) |tag| tag else ""),
                    });
                    break :blk;
                } else if (this.isFlags(param.param_type.name)) {
                    try this.renderTypeInfo(writer, param.param_type);
                    break :blk;
                }
            }

            try this.renderTypeInfo(writer, param.param_type);
        }

        try writer.writeAll(", ");
    }
    try writer.writeAll(") callconv(openxr_call_conv)");
    try this.renderTypeInfo(writer, command_ptr.return_type.*);
}

fn renderPointer(this: *Self, writer: *std.Io.Writer, pointer: c_types.Pointer) IdRenderer.Error!void {
    const child_is_void = pointer.child.* == .name and mem.eql(u8, pointer.child.name, "void");

    if (pointer.is_optional) {
        try writer.writeByte('?');
    }

    const size = if (child_is_void) .one else pointer.size;
    switch (size) {
        .one => try writer.writeByte('*'),
        .many, .other_field => try writer.writeAll("[*]"),
        .zero_terminated => try writer.writeAll("[*:0]"),
    }

    if (pointer.is_const) {
        try writer.writeAll("const ");
    }

    if (child_is_void) {
        try writer.writeAll("anyopaque");
    } else {
        try this.renderTypeInfo(writer, pointer.child.*);
    }
}

fn renderArray(this: *Self, writer: *std.Io.Writer, array: c_types.Array) !void {
    try writer.writeByte('[');
    switch (array.size) {
        .int => |size| try writer.print("{}", .{size}),
        .alias => |alias| try this.renderName(writer, alias),
    }
    try writer.writeByte(']');
    try this.renderTypeInfo(writer, array.child.*);
}

fn renderDecl(this: *Self, writer: *std.Io.Writer, decl: Registry.Declaration) !void {
    switch (decl.decl_type) {
        .container => |container| try this.renderContainer(writer, decl.name, container),
        .enumeration => |enumeration| try this.renderEnumeration(writer, decl.name, enumeration),
        .handle => |handle| try this.renderHandle(writer, decl.name, handle),
        .alias => |alias| try this.renderAlias(writer, decl.name, alias),
        .foreign => |foreign| try this.renderForeign(writer, decl.name, foreign),
        .typedef => |type_info| try this.renderTypedef(writer, decl.name, type_info),
        .external => try this.renderExternal(writer, decl.name),
        .command, .bitmask => {},
    }
}

fn renderContainer(
    this: *Self,
    writer: *std.Io.Writer,
    name: []const u8,
    container: Container,
) !void {
    try writer.writeAll("pub const ");
    try this.renderName(writer, name);
    try writer.writeAll(" = ");

    for (container.fields) |field| {
        if (field.bits != null) {
            return error.UnhandledBitfieldStruct;
        }
    } else {
        try writer.writeAll("extern ");
    }

    if (container.is_union) {
        try writer.writeAll("union {");
    } else {
        try writer.writeAll("struct {");
    }

    for (container.fields) |field| {
        try this.writeIdentifierWithCase(writer, .snake, field.name);
        try writer.writeAll(": ");
        if (field.bits) |bits| {
            try writer.print(" u{},", .{bits});
            if (field.field_type != .name or builtin_types.get(field.field_type.name) == null) {
                try writer.writeAll("// ");
                try this.renderTypeInfo(writer, field.field_type);
                try writer.writeByte('\n');
            }
        } else {
            try this.renderTypeInfo(writer, field.field_type);
            if (!container.is_union) {
                try this.renderContainerDefaultField(writer, container, name, field);
            }
            try writer.writeAll(", ");
        }
    }

    if (!container.is_union) {
        const have_next_or_type = for (container.fields) |field| {
            if (mem.eql(u8, field.name, "next") or mem.eql(u8, field.name, "type")) {
                break true;
            }
        } else false;

        if (have_next_or_type) {
            try writer.writeAll(
                \\    pub fn empty() @This() {
                \\        var value: @This() = undefined;
            );

            for (container.fields) |field| {
                if (mem.eql(u8, field.name, "next") or mem.eql(u8, field.name, "type")) {
                    try writer.writeAll("value.");
                    try this.writeIdentifierWithCase(writer, .snake, field.name);
                    try this.renderContainerDefaultField(writer, container, name, field);
                    try writer.writeAll(";\n");
                }
            }

            try writer.writeAll(
                \\        return value;
                \\    }
            );
        }
    }

    try writer.writeAll("};\n");
}

fn renderContainerDefaultField(
    this: *Self,
    writer: *std.Io.Writer,
    container: Container,
    container_name: []const u8,
    field: Container.Field,
) !void {
    if (mem.eql(u8, field.name, "next")) {
        try writer.writeAll(" = null");
    } else if (mem.eql(u8, field.name, "type")) {
        if (container.stype == null) {
            return;
        }

        const stype = container.stype.?;
        if (!mem.startsWith(u8, stype, "XR_TYPE_")) {
            return error.InvalidRegistry;
        }

        try writer.writeAll(" = .");
        try this.writeIdentifierWithCase(writer, .snake, stype["XR_TYPE_".len..]);
    } else if (mem.eql(u8, field.name, "w") and mem.eql(u8, container_name, "XrQuaternionf")) {
        try writer.writeAll(" = 1");
    } else if (field.is_optional) {
        if (field.field_type == .name) {
            const field_type_name = field.field_type.name;
            if (this.resolveDeclaration(field_type_name)) |decl_type| {
                if (decl_type == .handle) {
                    try writer.writeAll(" = .null_handle");
                } else if (decl_type == .bitmask) {
                    try writer.writeAll(" = .{}");
                } else if (decl_type == .typedef and decl_type.typedef == .command_ptr) {
                    try writer.writeAll(" = null");
                } else if ((decl_type == .typedef and builtin_types.has(decl_type.typedef.name)) or
                    (decl_type == .foreign and builtin_types.has(field_type_name)))
                {
                    try writer.writeAll(" = 0");
                }
            }
        } else if (field.field_type == .pointer) {
            try writer.writeAll(" = null");
        }
    } else if (field.field_type == .pointer and field.field_type.pointer.is_optional) {
        // pointer nullability could be here or above
        try writer.writeAll(" = null");
    } else if (initialized_types.get(container_name)) |value| {
        try writer.writeAll(" = ");
        try writer.writeAll(value);
    }
}

fn renderEnumFieldName(this: *Self, writer: *std.Io.Writer, name: []const u8, field_name: []const u8) !void {
    try this.writeIdentifierWithCase(writer, .snake, try this.extractEnumFieldName(name, field_name));
}

fn renderEnumeration(this: *Self, writer: *std.Io.Writer, name: []const u8, enumeration: Registry.Enum) !void {
    if (enumeration.is_bitmask) {
        try this.renderBitmaskBits(writer, name, enumeration);
        return;
    }

    try writer.writeAll("pub const ");
    try this.renderName(writer, name);
    try writer.writeAll(" = enum(i32) {");

    for (enumeration.fields) |field| {
        if (field.value == .alias)
            continue;

        try this.renderEnumFieldName(writer, name, field.name);
        switch (field.value) {
            .int => |int| try writer.print(" = {}, ", .{int}),
            .bitpos => |pos| try writer.print(" = 1 << {}, ", .{pos}),
            .bit_vector => |bv| try writer.print("= 0x{X}, ", .{bv}),
            .alias => unreachable,
        }
    }

    try writer.writeAll("_,");

    for (enumeration.fields) |field| {
        if (field.value != .alias or field.value.alias.is_compat_alias)
            continue;

        try writer.writeAll("pub const ");
        try this.renderEnumFieldName(writer, name, field.name);
        try writer.writeAll(" = ");
        try this.renderName(writer, name);
        try writer.writeByte('.');
        try this.renderEnumFieldName(writer, name, field.value.alias.name);
        try writer.writeAll(";\n");
    }

    try writer.writeAll("};\n");
}

fn renderBitmaskBits(this: *Self, writer: *std.Io.Writer, name: []const u8, bits: Registry.Enum) !void {
    try writer.writeAll("pub const ");
    try this.renderName(writer, name);
    try writer.writeAll(" = packed struct {");

    if (bits.fields.len == 0) {
        try writer.writeAll("_reserved_bits: Flags64 = 0,");
    } else {
        var flags_by_bitpos = [_]?[]const u8{null} ** 64;
        for (bits.fields) |field| {
            if (field.value == .bitpos) {
                flags_by_bitpos[field.value.bitpos] = field.name;
            }
        }

        for (flags_by_bitpos, 0..) |opt_flag_name, bitpos| {
            if (opt_flag_name) |flag_name| {
                try this.renderEnumFieldName(writer, name, flag_name);
            } else {
                try writer.print("_reserved_bit_{}", .{bitpos});
            }

            try writer.writeAll(":bool = false, ");
        }
    }
    try writer.writeAll("//pub usingnamespace FlagsMixin(");
    try this.renderName(writer, name);
    try writer.writeAll(");\n};\n");
}

fn renderHandle(this: *Self, writer: *std.Io.Writer, name: []const u8, handle: Registry.Handle) !void {
    const backing_type: []const u8 = if (handle.is_dispatchable) "usize" else "u64";

    try writer.writeAll("pub const ");
    try this.renderName(writer, name);
    try writer.print(" = enum({s}) {{null_handle = 0, _}};\n", .{backing_type});
}

fn renderAlias(this: *Self, writer: *std.Io.Writer, name: []const u8, alias: Registry.Alias) !void {
    if (alias.target == .other_command) {
        return;
    } else if (this.extractBitflagName(name) != null) {
        // Don't make aliases of the bitflag names, as those are replaced by just the flags type
        return;
    }

    try writer.writeAll("pub const ");
    try this.renderName(writer, name);
    try writer.writeAll(" = ");
    try this.renderName(writer, alias.name);
    try writer.writeAll(";\n");
}

fn renderExternal(this: *Self, writer: *std.Io.Writer, name: []const u8) !void {
    try writer.writeAll("pub const ");
    try this.renderName(writer, name);
    try writer.writeAll(" = opaque {};\n");
}

fn renderForeign(this: *Self, writer: *std.Io.Writer, name: []const u8, foreign: Registry.Foreign) !void {
    if (mem.eql(u8, foreign.depends, "openxr_platform_defines")) {
        return; // Skip built-in types, they are handled differently
    }

    try writer.writeAll("pub const ");
    try this.writeIdentifier(writer, name);
    try writer.print(" = if (@hasDecl(root, \"{s}\")) root.", .{name});
    try this.writeIdentifier(writer, name);
    try writer.writeAll(" else ");

    if (foreign_types.get(name)) |default| {
        try writer.writeAll(default);
        try writer.writeAll(";\n");
    } else {
        try writer.print("@compileError(\"Missing type definition of '{s}'\");\n", .{name});
    }
}

fn renderTypedef(this: *Self, writer: *std.Io.Writer, name: []const u8, type_info: c_types.TypeInfo) !void {
    try writer.writeAll("pub const ");
    try this.renderName(writer, name);
    try writer.writeAll(" = ");
    try this.renderTypeInfo(writer, type_info);
    try writer.writeAll(";\n");
}

fn renderCommandPtrName(this: *Self, writer: *std.Io.Writer, name: []const u8) !void {
    try this.writeIdentifierFmt(writer, "Pfn{s}", .{trimXrNamespace(name)});
}

fn renderCommandPtrs(this: *Self, writer: *std.Io.Writer) !void {
    for (this.registry.decls) |decl| {
        switch (decl.decl_type) {
            .command => {
                try writer.writeAll("pub const ");
                try this.renderCommandPtrName(writer, decl.name);
                try writer.writeAll(" = ");
                try this.renderCommandPtr(writer, decl.decl_type.command, false);
                try writer.writeAll(";\n");
            },
            .alias => |alias| if (alias.target == .other_command) {
                try writer.writeAll("pub const ");
                try this.renderCommandPtrName(writer, decl.name);
                try writer.writeAll(" = ");
                try this.renderCommandPtrName(writer, alias.name);
                try writer.writeAll(";\n");
            },
            else => {},
        }
    }
}

fn renderExtensionInfo(this: *Self, writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\pub const extension_info = struct {
        \\    const Info = struct {
        \\        name: [:0]const u8,
        \\        version: u32,
        \\    };
    );
    for (this.registry.extensions) |ext| {
        try writer.writeAll("pub const ");
        try this.writeIdentifierWithCase(writer, .snake, trimXrNamespace(ext.name));
        try writer.writeAll("= Info {\n");
        try writer.print(".name = \"{s}\", .version = {},", .{ ext.name, ext.version });
        try writer.writeAll("};\n");
    }
    try writer.writeAll("};\n");
}

fn renderWrappers(this: *Self, writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\pub fn CommandFlagsMixin(comptime CommandFlags: type) type {
        \\    return struct {
        \\        pub fn merge(lhs: CommandFlags, rhs: CommandFlags) CommandFlags {
        \\            var result: CommandFlags = .{};
        \\            inline for (@typeInfo(CommandFlags).@"struct".fields) |field| {
        \\                @field(result, field.name) = @field(lhs, field.name) or @field(rhs, field.name);
        \\            }
        \\            return result;
        \\        }
        \\        pub fn intersect(lhs: CommandFlags, rhs: CommandFlags) CommandFlags {
        \\            var result: CommandFlags = .{};
        \\            inline for (@typeInfo(CommandFlags).@"struct".fields) |field| {
        \\                @field(result, field.name) = @field(lhs, field.name) and @field(rhs, field.name);
        \\            }
        \\            return result;
        \\        }
        \\        pub fn complement(this: CommandFlags) CommandFlags {
        \\            var result: CommandFlags = .{};
        \\            inline for (@typeInfo(CommandFlags).@"struct".fields) |field| {
        \\                @field(result, field.name) = !@field(this, field.name);
        \\            }
        \\            return result;
        \\        }
        \\        pub fn subtract(lhs: CommandFlags, rhs: CommandFlags) CommandFlags {
        \\            var result: CommandFlags = .{};
        \\            inline for (@typeInfo(CommandFlags).@"struct".fields) |field| {
        \\                @field(result, field.name) = @field(lhs, field.name) and !@field(rhs, field.name);
        \\            }
        \\            return result;
        \\        }
        \\        pub fn contains(lhs: CommandFlags, rhs: CommandFlags) bool {
        \\            inline for (@typeInfo(CommandFlags).@"struct".fields) |field| {
        \\                if (!@field(lhs, field.name) and @field(rhs, field.name)) {
        \\                    return false;
        \\                }
        \\            }
        \\            return true;
        \\        }
        \\    };
        \\}
        \\
    );
    try this.renderWrappersOfDispatchType(writer, .base);
    try this.renderWrappersOfDispatchType(writer, .instance);
}

fn renderWrappersOfDispatchType(this: *Self, writer: *std.Io.Writer, dispatch_type: CommandDispatchType) !void {
    const name = switch (dispatch_type) {
        .base => "Base",
        .instance => "Instance",
    };

    try writer.print(
        \\pub const {0s}CommandFlags = packed struct {{
        \\
    , .{name});
    for (this.registry.decls) |decl| {
        // If the target type does not exist, it was likely an empty enum -
        // assume spec is correct and that this was not a function alias.
        const decl_type = this.resolveAlias(decl.decl_type) catch continue;
        const command = switch (decl_type) {
            .command => |cmd| cmd,
            else => continue,
        };

        if (classifyCommandDispatch(decl.name, command) == dispatch_type) {
            try writer.writeAll("    ");
            try this.writeIdentifierWithCase(writer, .camel, trimXrNamespace(decl.name));
            try writer.writeAll(": bool = false,\n");
        }
    }

    try writer.print(
        \\pub fn CmdType(comptime tag: std.meta.FieldEnum({0s}CommandFlags)) type {{
        \\    return switch (tag) {{
        \\
    , .{name});
    for (this.registry.decls) |decl| {
        // If the target type does not exist, it was likely an empty enum -
        // assume spec is correct and that this was not a function alias.
        const decl_type = this.resolveAlias(decl.decl_type) catch continue;
        const command = switch (decl_type) {
            .command => |cmd| cmd,
            else => continue,
        };

        if (classifyCommandDispatch(decl.name, command) == dispatch_type) {
            try writer.writeAll((" " ** 8) ++ ".");
            try this.writeIdentifierWithCase(writer, .camel, trimXrNamespace(decl.name));
            try writer.writeAll(" => ");
            try this.renderCommandPtrName(writer, decl.name);
            try writer.writeAll(",\n");
        }
    }
    try writer.writeAll("    };\n}");

    try writer.print(
        \\pub fn cmdName(tag: std.meta.FieldEnum({0s}CommandFlags)) [:0]const u8 {{
        \\    return switch(tag) {{
        \\
    , .{name});
    for (this.registry.decls) |decl| {
        // If the target type does not exist, it was likely an empty enum -
        // assume spec is correct and that this was not a function alias.
        const decl_type = this.resolveAlias(decl.decl_type) catch continue;
        const command = switch (decl_type) {
            .command => |cmd| cmd,
            else => continue,
        };

        if (classifyCommandDispatch(decl.name, command) == dispatch_type) {
            try writer.writeAll((" " ** 8) ++ ".");
            try this.writeIdentifierWithCase(writer, .camel, trimXrNamespace(decl.name));
            try writer.print(
                \\ => "{s}",
                \\
            , .{decl.name});
        }
    }
    try writer.writeAll("    };\n}");

    try writer.print(
        \\  //pub usingnamespace CommandFlagsMixin({s}CommandFlags);
        \\}};
        \\
    , .{name});

    try writer.print(
        \\pub fn {0s}Wrapper(comptime cmds: {0s}CommandFlags) type {{
        \\    return struct {{
        \\        dispatch: Dispatch,
        \\
        \\        const Self = @This();
        \\        pub const commands = cmds;
        \\        pub const Dispatch = blk: {{
        \\            @setEvalBranchQuota(10_000);
        \\            const Type = std.builtin.Type;
        \\            const fields_len = fields_len: {{
        \\                var fields_len = 0;
        \\                for (@typeInfo({0s}CommandFlags).@"struct".fields) |field| {{
        \\                    fields_len += @intFromBool(@field(cmds, field.name));
        \\                }}
        \\                break :fields_len fields_len;
        \\            }};
        \\            var fields: [fields_len]Type.StructField = undefined;
        \\            var i: usize = 0;
        \\            for (@typeInfo({0s}CommandFlags).@"struct".fields) |field| {{
        \\                if (@field(cmds, field.name)) {{
        \\                    const field_tag = std.enums.nameCast(std.meta.FieldEnum({0s}CommandFlags), field.name);
        \\                    const PfnType = {0s}CommandFlags.CmdType(field_tag);
        \\                    fields[i] = .{{
        \\                        .name = {0s}CommandFlags.cmdName(field_tag),
        \\                        .type = PfnType,
        \\                        .default_value_ptr = null,
        \\                        .is_comptime = false,
        \\                        .alignment = @alignOf(PfnType),
        \\                    }};
        \\                    i += 1;
        \\                }}
        \\            }}
        \\            break :blk @Type(.{{
        \\                .@"struct" = .{{
        \\                    .layout = .auto,
        \\                    .fields = &fields,
        \\                    .decls = &[_]std.builtin.Type.Declaration{{}},
        \\                    .is_tuple = false,
        \\                }},
        \\            }});
        \\        }};
        \\
    , .{name});

    try this.renderWrapperLoader(writer, dispatch_type);

    for (this.registry.decls) |decl| {
        // If the target type does not exist, it was likely an empty enum -
        // assume spec is correct and that this was not a function alias.
        const decl_type = this.resolveAlias(decl.decl_type) catch continue;
        const command = switch (decl_type) {
            .command => |cmd| cmd,
            else => continue,
        };

        if (classifyCommandDispatch(decl.name, command) != dispatch_type) {
            continue;
        }
        // Note: If this decl is an alias, generate a full wrapper instead of simply an
        // alias like `const old = new;`. This ensures that OpenXR bindings generated
        // for newer versions of openxr can still invoke extension behavior on older
        // implementations.
        try this.renderWrapper(writer, decl.name, command);
    }

    try writer.writeAll("};}\n");
}

fn renderWrapperLoader(_: *Self, writer: *std.Io.Writer, dispatch_type: CommandDispatchType) !void {
    const params = switch (dispatch_type) {
        .base => "loader: anytype",
        .instance => "instance: Instance, loader: anytype",
    };

    const loader_first_arg = switch (dispatch_type) {
        .base => "Instance.null_handle",
        .instance => "instance",
    };

    @setEvalBranchQuota(2000);

    try writer.print(
        \\pub fn load({[params]s}) error{{CommandLoadFailure}}!Self {{
        \\    var this: Self = undefined;
        \\    inline for (std.meta.fields(Dispatch)) |field| {{
        \\        const name: [*:0]const u8 = @ptrCast(field.name ++ "\x00");
        \\        var cmd_ptr: PfnVoidFunction = undefined;
        \\        const result: Result = loader({[first_arg]s}, name, &cmd_ptr);
        \\        if (result != .success) return error.CommandLoadFailure;
        \\        @field(this.dispatch, field.name) = @ptrCast(cmd_ptr);
        \\    }}
        \\    return this;
        \\}}
        \\pub fn loadNoFail({[params]s}) Self {{
        \\    var this: Self = undefined;
        \\    inline for (std.meta.fields(Dispatch)) |field| {{
        \\        const name: [*:0]const u8 = @ptrCast(field.name ++ "\x00");
        \\        var cmd_ptr: PfnVoidFunction = undefined;
        \\        if (loader({[first_arg]s}, name, &cmd_ptr)) {{
        \\          @field(this.dispatch, field.name) = @ptrCast(cmd_ptr);
        \\        }}
        \\    }}
        \\    return this;
        \\}}
    , .{ .params = params, .first_arg = loader_first_arg });
}

fn derefName(name: []const u8) []const u8 {
    var it = IdRenderer.SegmentIterator.init(name);
    return if (mem.eql(u8, it.next().?, "p"))
        name[1..]
    else
        name;
}

fn renderWrapperPrototype(this: *Self, writer: *std.Io.Writer, name: []const u8, command: Registry.Command, returns: []const ReturnValue) !void {
    try writer.writeAll("pub fn ");
    try this.writeIdentifierWithCase(writer, .camel, trimXrNamespace(name));
    try writer.writeAll("(this: Self, ");

    for (command.params) |param| {
        // This parameter is returned instead.
        if ((try this.classifyParam(param)) == .out_pointer) {
            continue;
        }

        try this.writeIdentifierWithCase(writer, .snake, param.name);
        try writer.writeAll(": ");
        try this.renderTypeInfo(writer, param.param_type);
        try writer.writeAll(", ");
    }

    try writer.writeAll(") ");

    const returns_xr_result = command.return_type.* == .name and mem.eql(u8, command.return_type.name, "XrResult");
    if (returns_xr_result) {
        try this.renderErrorSetName(writer, name);
        try writer.writeByte('!');
    }

    if (returns.len == 1) {
        try this.renderTypeInfo(writer, returns[0].return_value_type);
    } else if (returns.len > 1) {
        try this.renderReturnStructName(writer, name);
    } else {
        try writer.writeAll("void");
    }
}

fn renderWrapperCall(this: *Self, writer: *std.Io.Writer, name: []const u8, command: Registry.Command, returns: []const ReturnValue) !void {
    try writer.writeAll("this.dispatch.");
    try this.writeIdentifier(writer, name);
    try writer.writeAll("(");

    for (command.params) |param| {
        switch (try this.classifyParam(param)) {
            .out_pointer => {
                try writer.writeByte('&');
                if (returns.len > 1) {
                    try writer.writeAll("return_values.");
                }
                try this.writeIdentifierWithCase(writer, .snake, derefName(param.name));
            },
            .bitflags, .in_pointer, .in_out_pointer, .buffer_len, .mut_buffer_len, .other => {
                try this.writeIdentifierWithCase(writer, .snake, param.name);
            },
        }

        try writer.writeAll(", ");
    }
    try writer.writeAll(")");
}

fn extractReturns(this: *Self, command: Registry.Command) ![]const ReturnValue {
    var returns = std.array_list.Managed(ReturnValue).init(this.allocator);

    if (command.return_type.* == .name) {
        const return_name = command.return_type.name;
        if (!mem.eql(u8, return_name, "void") and !mem.eql(u8, return_name, "XrResult")) {
            try returns.append(.{
                .name = "return_value",
                .return_value_type = command.return_type.*,
                .origin = .inner_return_value,
            });
        }
    }

    if (command.success_codes.len > 1) {
        if (command.return_type.* != .name or !mem.eql(u8, command.return_type.name, "XrResult")) {
            return error.InvalidRegistry;
        }

        try returns.append(.{
            .name = "result",
            .return_value_type = command.return_type.*,
            .origin = .inner_return_value,
        });
    } else if (command.success_codes.len == 1 and !mem.eql(u8, command.success_codes[0], "XR_SUCCESS")) {
        return error.InvalidRegistry;
    }

    for (command.params) |param| {
        if ((try this.classifyParam(param)) == .out_pointer) {
            try returns.append(.{
                .name = derefName(param.name),
                .return_value_type = param.param_type.pointer.child.*,
                .origin = .parameter,
            });
        }
    }

    return try returns.toOwnedSlice();
}

fn renderReturnStructName(this: *Self, writer: *std.Io.Writer, command_name: []const u8) !void {
    try this.writeIdentifierFmt(writer, "{s}Result", .{trimXrNamespace(command_name)});
}

fn renderErrorSetName(this: *Self, writer: *std.Io.Writer, name: []const u8) !void {
    try this.writeIdentifierWithCase(writer, .title, trimXrNamespace(name));
    try writer.writeAll("Error");
}

fn renderReturnStruct(this: *Self, writer: *std.Io.Writer, command_name: []const u8, returns: []const ReturnValue) !void {
    try writer.writeAll("pub const ");
    try this.renderReturnStructName(writer, command_name);
    try writer.writeAll(" = struct {\n");
    for (returns) |ret| {
        try this.writeIdentifierWithCase(writer, .snake, ret.name);
        try writer.writeAll(": ");
        try this.renderTypeInfo(writer, ret.return_value_type);
        try writer.writeAll(", ");
    }
    try writer.writeAll("};\n");
}

fn renderWrapper(this: *Self, writer: *std.Io.Writer, name: []const u8, command: Registry.Command) !void {
    const returns_xr_result = command.return_type.* == .name and mem.eql(u8, command.return_type.name, "XrResult");
    const returns_void = command.return_type.* == .name and mem.eql(u8, command.return_type.name, "void");

    const returns = try this.extractReturns(command);

    if (returns.len > 1) {
        try this.renderReturnStruct(writer, name, returns);
    }

    if (returns_xr_result) {
        try writer.writeAll("pub const ");
        try this.renderErrorSetName(writer, name);
        try writer.writeAll(" = ");
        try this.renderErrorSet(writer, command.error_codes);
        try writer.writeAll(";\n");
    }

    try this.renderWrapperPrototype(writer, name, command, returns);

    if (returns.len == 1 and returns[0].origin == .inner_return_value) {
        try writer.writeAll("{\n\n");

        if (returns_xr_result) {
            try writer.writeAll("const result = ");
            try this.renderWrapperCall(writer, name, command, returns);
            try writer.writeAll(";\n");

            try this.renderErrorSwitch(writer, "result", command);
            try writer.writeAll("return result;\n");
        } else {
            try writer.writeAll("return ");
            try this.renderWrapperCall(writer, name, command, returns);
            try writer.writeAll(";\n");
        }

        try writer.writeAll("\n}\n");
        return;
    }

    try writer.writeAll("{\n");
    if (returns.len == 1) {
        try writer.writeAll("var ");
        try this.writeIdentifierWithCase(writer, .snake, returns[0].name);
        try writer.writeAll(": ");
        try this.renderTypeInfo(writer, returns[0].return_value_type);
        try writer.writeAll(" = undefined;\n");
    } else if (returns.len > 1) {
        try writer.writeAll("var return_values: ");
        try this.renderReturnStructName(writer, name);
        try writer.writeAll(" = undefined;\n");
    }

    if (returns_xr_result) {
        try writer.writeAll("const result = ");
        try this.renderWrapperCall(writer, name, command, returns);
        try writer.writeAll(";\n");

        try this.renderErrorSwitch(writer, "result", command);
        if (command.success_codes.len > 1) {
            try writer.writeAll("return_values.result = result;\n");
        }
    } else {
        if (!returns_void) {
            try writer.writeAll("return_values.return_value = ");
        }
        try this.renderWrapperCall(writer, name, command, returns);
        try writer.writeAll(";\n");
    }

    if (returns.len == 1) {
        try writer.writeAll("return ");
        try this.writeIdentifierWithCase(writer, .snake, returns[0].name);
        try writer.writeAll(";\n");
    } else if (returns.len > 1) {
        try writer.writeAll("return return_values;\n");
    }

    try writer.writeAll("}\n");
}

fn renderErrorSwitch(this: *Self, writer: *std.Io.Writer, result_var: []const u8, command: Registry.Command) !void {
    try writer.writeAll("switch (");
    try this.writeIdentifier(writer, result_var);
    try writer.writeAll(") {\n");

    for (command.success_codes) |success| {
        try writer.writeAll("Result.");
        try this.renderEnumFieldName(writer, "XrResult", success);
        try writer.writeAll(" => {},");
    }

    for (command.error_codes) |err| {
        try writer.writeAll("Result.");
        try this.renderEnumFieldName(writer, "XrResult", err);
        try writer.writeAll(" => return error.");
        try this.renderResultAsErrorName(writer, err);
        try writer.writeAll(", ");
    }

    try writer.writeAll("else => return error.Unknown,}\n");
}

fn renderErrorSet(this: *Self, writer: *std.Io.Writer, errors: []const []const u8) !void {
    try writer.writeAll("error{");
    for (errors) |name| {
        try this.renderResultAsErrorName(writer, name);
        try writer.writeAll(", ");
    }
    try writer.writeAll("Unknown, }");
}

fn renderResultAsErrorName(this: *Self, writer: *std.Io.Writer, name: []const u8) !void {
    const error_prefix = "XR_ERROR_";
    if (mem.startsWith(u8, name, error_prefix)) {
        try this.writeIdentifierWithCase(writer, .title, name[error_prefix.len..]);
    } else {
        // Apparently some commands (XrAcquireProfilingLockInfoKHR) return
        // success codes as error...
        try this.writeIdentifierWithCase(writer, .title, trimXrNamespace(name));
    }
}

// fn getOrCreateBuffer(this: *@This(), name: []const u8) !*std.array_list.Managed(u8) {
//     if (this.moduleFileMap.get(name)) |buf| {
//         return buf;
//     } else {
//         const buf = try this.allocator.create(std.array_list.Managed(u8));
//         buf.* = .init(this.allocator);
//         try this.moduleFileMap.put(name, buf);
//         return buf;
//     }
// }

pub fn render(this: *Self) !void {
    {
        var arena = std.heap.ArenaAllocator.init(this.allocator);
        defer arena.deinit();
        var allocating = std.Io.Writer.Allocating.init(arena.allocator());
        var writer = &allocating.writer;

        try writer.writeAll(@embedFile("template/preamble.zig"));

        for (this.registry.api_constants) |api_constant| {
            try this.renderApiConstant(writer, api_constant);
        }

        for (this.registry.decls) |decl| {
            try this.renderDecl(writer, decl);
        }

        try this.renderCommandPtrs(writer);

        const slice = try allocating.toOwnedSlice();
        try this.moduleFileMap.put(
            "core.zig",
            try std.fmt.allocPrintSentinel(this.allocator, "{s}", .{slice}, 0),
        );
    }

    // features/*.zig
    for (this.registry.features) |feature| {
        var arena = std.heap.ArenaAllocator.init(this.allocator);
        defer arena.deinit();
        var allocating = std.Io.Writer.Allocating.init(arena.allocator());
        var writer = &allocating.writer;

        try writer.writeAll(
            \\const core = @import("../core.zig");
            \\
            \\
        );
        for (feature.requires) |require| {
            for (require.commands) |command| {
                try writer.print("{s}: core.Pfn{s},\n", .{ command, command[2..] });
            }
        }

        const module_file = try std.fmt.allocPrint(this.allocator, "features/{s}.zig", .{feature.name});
        const slice = try allocating.toOwnedSlice();
        try this.moduleFileMap.put(
            module_file,
            try std.fmt.allocPrintSentinel(this.allocator, "{s}", .{slice}, 0),
        );
    }

    // features/features.zig
    {
        var arena = std.heap.ArenaAllocator.init(this.allocator);
        defer arena.deinit();
        var allocating = std.Io.Writer.Allocating.init(arena.allocator());
        var writer = &allocating.writer;

        for (this.registry.features) |feature| {
            try writer.print(
                \\pub const {s} = @import("{s}.zig");
                \\
            , .{
                feature.name, feature.name,
            });
        }

        const slice = try allocating.toOwnedSlice();
        try this.moduleFileMap.put(
            "features/features.zig",
            try std.fmt.allocPrintSentinel(this.allocator, "{s}", .{slice}, 0),
        );
    }

    // extensions/*.zig
    for (this.registry.extensions) |extension| {
        var arena = std.heap.ArenaAllocator.init(this.allocator);
        defer arena.deinit();
        var allocating = std.Io.Writer.Allocating.init(arena.allocator());
        var writer = &allocating.writer;

        try writer.writeAll(
            \\const core = @import("../core.zig");
            \\
            \\
        );
        for (extension.requires) |require| {
            for (require.commands) |command| {
                try writer.print("{s}: core.Pfn{s},\n", .{ command, command[2..] });
            }
        }

        const module_file = try std.fmt.allocPrint(this.allocator, "extensions/{s}.zig", .{extension.name});
        const slice = try allocating.toOwnedSlice();
        try this.moduleFileMap.put(
            module_file,
            try std.fmt.allocPrintSentinel(this.allocator, "{s}", .{slice}, 0),
        );
    }

    // extensions/extensions.zig
    {
        var arena = std.heap.ArenaAllocator.init(this.allocator);
        defer arena.deinit();
        var allocating = std.Io.Writer.Allocating.init(arena.allocator());
        var writer = &allocating.writer;

        for (this.registry.extensions) |extension| {
            try writer.print(
                \\pub const {s} = @import("{s}.zig");
                \\
            , .{
                extension.name, extension.name,
            });
        }

        const slice = try allocating.toOwnedSlice();
        try this.moduleFileMap.put(
            "extensions/extensions.zig",
            try std.fmt.allocPrintSentinel(this.allocator, "{s}", .{slice}, 0),
        );
    }

    // xr.zig
    {
        var arena = std.heap.ArenaAllocator.init(this.allocator);
        defer arena.deinit();
        var allocating = std.Io.Writer.Allocating.init(arena.allocator());
        var writer = &allocating.writer;

        try writer.writeAll(
            \\pub const features = @import("features/features.zig");
            \\pub const extensions = @import("extensions/extensions.zig");
            \\
        );
        try writer.writeAll(@embedFile("template/xr.zig"));

        const slice = try allocating.toOwnedSlice();
        try this.moduleFileMap.put(
            "xr.zig",
            try std.fmt.allocPrintSentinel(this.allocator, "{s}", .{slice}, 0),
        );
    }

    // try this.renderExtensionInfo(writer);
    // try this.renderWrappers(writer);
}
