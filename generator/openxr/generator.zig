const std = @import("std");
const reg = @import("registry.zig");
const renderRegistry = @import("render.zig").render;
const IdRenderer = @import("../id_render.zig").IdRenderer;
const mem = std.mem;
const Allocator = mem.Allocator;
const FeatureLevel = reg.FeatureLevel;

const EnumFieldMerger = struct {
    const EnumExtensionMap = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(reg.Enum.Field));
    const FieldSet = std.StringArrayHashMapUnmanaged(void);

    arena: Allocator,
    registry: *reg.Registry,
    enum_extensions: EnumExtensionMap,
    field_set: FieldSet,

    fn init(arena: Allocator, registry: *reg.Registry) EnumFieldMerger {
        return .{
            .arena = arena,
            .registry = registry,
            .enum_extensions = .{},
            .field_set = .{},
        };
    }

    fn putEnumExtension(self: *EnumFieldMerger, enum_name: []const u8, field: reg.Enum.Field) !void {
        const res = try self.enum_extensions.getOrPut(self.arena, enum_name);
        if (!res.found_existing) {
            res.value_ptr.* = std.ArrayListUnmanaged(reg.Enum.Field){};
        }

        try res.value_ptr.append(self.arena, field);
    }

    fn addRequires(self: *EnumFieldMerger, reqs: []const reg.Require) !void {
        for (reqs) |req| {
            for (req.extends) |enum_ext| {
                try self.putEnumExtension(enum_ext.extends, enum_ext.field);
            }
        }
    }

    fn mergeEnumFields(self: *EnumFieldMerger, name: []const u8, base_enum: *reg.Enum) !void {
        // If there are no extensions for this enum, assume its valid.
        const extensions = self.enum_extensions.get(name) orelse return;

        self.field_set.clearRetainingCapacity();

        const n_fields_upper_bound = base_enum.fields.len + extensions.items.len;
        const new_fields = try self.arena.alloc(reg.Enum.Field, n_fields_upper_bound);
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

    fn merge(self: *EnumFieldMerger) !void {
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

pub const Generator = struct {
    allocator: std.mem.Allocator,
    registry: reg.Registry,
    id_renderer: IdRenderer,

    pub fn init(allocator: std.mem.Allocator, registry: reg.Registry) !Generator {
        return Generator{
            .allocator = allocator,
            .registry = registry,
            .id_renderer = IdRenderer.init(allocator, registry.tags),
        };
    }

    pub fn removePromotedExtensions(self: *Generator) void {
        var write_index: usize = 0;
        for (self.registry.extensions) |ext| {
            if (ext.promoted_to == .none) {
                self.registry.extensions[write_index] = ext;
                write_index += 1;
            }
        }
        self.registry.extensions.len = write_index;
    }

    fn stripFlagBits(self: Generator, name: []const u8) []const u8 {
        const tagless = self.id_renderer.stripAuthorTag(name);
        return tagless[0 .. tagless.len - "FlagBits".len];
    }

    fn stripFlags(self: Generator, name: []const u8) []const u8 {
        const tagless = self.id_renderer.stripAuthorTag(name);
        return tagless[0 .. tagless.len - "Flags64".len];
    }

    // Solve `registry.declarations` according to `registry.extensions` and `registry.features`.
    pub fn mergeEnumFields(self: *Generator) !void {
        var merger = EnumFieldMerger.init(self.allocator, &self.registry);
        try merger.merge();
    }

    pub fn render(self: *Generator, writer: *std.io.Writer) !void {
        try renderRegistry(writer, self.allocator, &self.registry, &self.id_renderer);
    }
};
