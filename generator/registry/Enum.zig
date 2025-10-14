const std = @import("std");
const xml = @import("xml/xml.zig");
const XmlDocument = xml.XmlDocument;
const Element = XmlDocument.Element;

pub const Value = union(enum) {
    bitpos: u5, // 1 << bitpos
    bit_vector: i32, // Combined flags & some vendor IDs
    int: i32,
    alias: struct {
        name: []const u8,
        is_compat_alias: bool,
    },
};

pub const Field = struct {
    name: []const u8,
    value: Value,

    pub fn parse(field: *Element) !@This() {
        const is_compat_alias = if (field.getAttribute("comment")) |comment|
            std.mem.eql(u8, comment, "Backwards-compatible alias containing a typo") or
                std.mem.eql(u8, comment, "Deprecated name for backwards compatibility")
        else
            false;

        const name = field.getAttribute("name") orelse return error.InvalidRegistry;
        const value: Value = blk: {
            // An enum variant's value could be defined by any of the following attributes:
            // - value: Straight up value of the enum variant, in either base 10 or 16 (prefixed with 0x).
            // - bitpos: Used for bitmasks, and can also be set in extensions.
            // - alias: The field is an alias of another variant within the same enum.
            // - offset: Used with features and extensions, where a non-bitpos value is added to an enum.
            //     The value is given by `1e9 + (extr_nr - 1) * 1e3 + offset`, where `ext_nr` is either
            //     given by the `extnumber` field (in the case of a feature), or given in the parent <extension>
            //     tag. In the latter case its passed via the `ext_nr` parameter.
            if (field.getAttribute("value")) |value| {
                if (std.mem.startsWith(u8, value, "0x")) {
                    break :blk .{ .bit_vector = try std.fmt.parseInt(i32, value[2..], 16) };
                } else {
                    break :blk .{ .int = try std.fmt.parseInt(i32, value, 10) };
                }
            } else if (field.getAttribute("bitpos")) |bitpos| {
                break :blk .{ .bitpos = try std.fmt.parseInt(u5, bitpos, 10) };
            } else if (field.getAttribute("alias")) |alias| {
                break :blk .{ .alias = .{ .name = alias, .is_compat_alias = is_compat_alias } };
            } else {
                return error.InvalidRegistry;
            }
        };

        return @This(){
            .name = name,
            .value = value,
        };
    }
};

fields: []Field,
is_bitmask: bool,

pub fn parse(allocator: std.mem.Allocator, elem: *Element) !@This() {
    // TODO: `type` was added recently, fall back to checking endswith FlagBits for older versions?
    const enum_type = elem.getAttribute("type") orelse return error.InvalidRegistry;
    const is_bitmask = std.mem.eql(u8, enum_type, "bitmask");
    if (!is_bitmask and !std.mem.eql(u8, enum_type, "enum")) {
        return error.InvalidRegistry;
    }

    const fields = try allocator.alloc(Field, elem.children.len);

    var i: usize = 0;
    var it = elem.findChildrenByTag("enum");
    while (it.next()) |field| {
        fields[i] = try Field.parse(field);
        i += 1;
    }

    return @This(){
        .fields = fields[0..i],
        .is_bitmask = is_bitmask,
    };
}
