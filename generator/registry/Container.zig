const std = @import("std");
const c_types = @import("c_types.zig");
const xml = @import("xml/xml.zig");
const XmlElement = xml.XmlDocument.Element;

pub const Field = struct {
    name: []const u8,
    field_type: c_types.TypeInfo,
    bits: ?usize,
    is_buffer_len: bool,
    is_optional: bool,
};

stype: ?[]const u8,
extends: ?[]const []const u8,
fields: []Field,
is_union: bool,

fn lenToPointer(members: []Field, len: []const u8) std.meta.Tuple(&.{
    c_types.Pointer.PointerSize,
    bool,
}) {
    for (members) |*member| {
        if (std.mem.eql(u8, member.name, len)) {
            member.is_buffer_len = true;
            return .{ .{ .other_field = member.name }, member.is_optional };
        }
    }
    if (std.mem.eql(u8, len, "null-terminated")) {
        return .{ .zero_terminated, false };
    } else {
        return .{ .many, false };
    }
}

pub fn parsePointerMeta(
    fields: []Field,
    type_info: *c_types.TypeInfo,
    elem: *XmlElement,
) !void {
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
