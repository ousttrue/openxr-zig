const std = @import("std");
const xml = @import("xml/xml.zig");
const XmlElement = xml.XmlDocument.Element;
const ApiConstant = @import("ApiConstant.zig");
const Enum = @import("Enum.zig");
const Extension = @import("Extension.zig");
const Feature = @import("Feature.zig");
const Declaration = @import("Declaration.zig");
const Require = @import("Require.zig");

const EnumFieldMerger = struct {
    enum_extensions: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Enum.Field)),
    field_set: std.StringArrayHashMapUnmanaged(void),

    pub fn init() @This() {
        return .{
            .enum_extensions = .{},
            .field_set = .{},
        };
    }

    fn putEnumExtension(
        self: *@This(),
        allocator: std.mem.Allocator,
        enum_name: []const u8,
        field: Enum.Field,
    ) !void {
        const res = try self.enum_extensions.getOrPut(allocator, enum_name);
        if (!res.found_existing) {
            res.value_ptr.* = std.ArrayListUnmanaged(Enum.Field){};
        }

        try res.value_ptr.append(allocator, field);
    }

    fn addRequires(self: *@This(), allocator: std.mem.Allocator, reqs: []const Require) !void {
        for (reqs) |req| {
            for (req.extends) |enum_ext| {
                try self.putEnumExtension(allocator, enum_ext.extends, enum_ext.field);
            }
        }
    }

    fn mergeEnumFields(
        self: *@This(),
        allocator: std.mem.Allocator,
        name: []const u8,
        base_enum: *Enum,
    ) !void {
        // If there are no extensions for this enum, assume its valid.
        const extensions = self.enum_extensions.get(name) orelse return;

        self.field_set.clearRetainingCapacity();

        const n_fields_upper_bound = base_enum.fields.len + extensions.items.len;
        const new_fields = try allocator.alloc(Enum.Field, n_fields_upper_bound);
        var i: usize = 0;

        for (base_enum.fields) |field| {
            const res = try self.field_set.getOrPut(allocator, field.name);
            if (!res.found_existing) {
                new_fields[i] = field;
                i += 1;
            }
        }

        // Assume that if a field name clobbers, the value is the same
        for (extensions.items) |field| {
            const res = try self.field_set.getOrPut(allocator, field.name);
            if (!res.found_existing) {
                new_fields[i] = field;
                i += 1;
            }
        }

        // Existing base_enum.fields was allocated by `self.arena`, so
        // it gets cleaned up whenever that is deinited.
        base_enum.fields = new_fields[0..i];
    }

    pub fn merge(
        self: *@This(),
        allocator: std.mem.Allocator,
        features: []Feature,
        extensions: []Extension,
        decls: []Declaration,
    ) !void {
        for (features) |feature| {
            try self.addRequires(allocator, feature.requires);
        }

        for (extensions) |ext| {
            try self.addRequires(allocator, ext.requires);
        }

        // Merge all the enum fields.
        // Assume that all keys of enum_extensions appear in `self.registry.decls`
        for (decls) |*decl| {
            if (decl.decl_type == .enumeration) {
                try self.mergeEnumFields(allocator, decl.name, &decl.decl_type.enumeration);
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
        .decls = try Declaration.parseDeclarations(allocator, doc.root),
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
    var merger = EnumFieldMerger.init();
    try merger.merge(allocator, registry.features, registry.extensions, registry.decls);

    return registry;
}
