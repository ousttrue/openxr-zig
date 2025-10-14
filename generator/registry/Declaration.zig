const Container = @import("Container.zig");
const Enum = @import("Enum.zig");
const c_types = @import("c_types.zig");

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
