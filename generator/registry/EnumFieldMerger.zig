const std = @import("std");
const Registry = @import("Registry.zig");

arena: std.mem.Allocator,
registry: *Registry,
enum_extensions: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Registry.Enum.Field)),
field_set: std.StringArrayHashMapUnmanaged(void),

pub fn init(arena: std.mem.Allocator, registry: *Registry) @This() {
    return .{
        .arena = arena,
        .registry = registry,
        .enum_extensions = .{},
        .field_set = .{},
    };
}

fn putEnumExtension(self: *@This(), enum_name: []const u8, field: Registry.Enum.Field) !void {
    const res = try self.enum_extensions.getOrPut(self.arena, enum_name);
    if (!res.found_existing) {
        res.value_ptr.* = std.ArrayListUnmanaged(Registry.Enum.Field){};
    }

    try res.value_ptr.append(self.arena, field);
}

fn addRequires(self: *@This(), reqs: []const Registry.Require) !void {
    for (reqs) |req| {
        for (req.extends) |enum_ext| {
            try self.putEnumExtension(enum_ext.extends, enum_ext.field);
        }
    }
}

fn mergeEnumFields(self: *@This(), name: []const u8, base_enum: *Registry.Enum) !void {
    // If there are no extensions for this enum, assume its valid.
    const extensions = self.enum_extensions.get(name) orelse return;

    self.field_set.clearRetainingCapacity();

    const n_fields_upper_bound = base_enum.fields.len + extensions.items.len;
    const new_fields = try self.arena.alloc(Registry.Enum.Field, n_fields_upper_bound);
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
