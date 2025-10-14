const std = @import("std");
const xml = @import("xml/xml.zig");
const XmlDocument = xml.XmlDocument;
const Element = XmlDocument.Element;
const Enum = @import("Enum.zig");
const FeatureLevel = @import("FeatureLevel.zig");

pub const EnumExtension = struct {
    extends: []const u8,
    extnumber: ?u31,
    field: Enum.Field,

    fn parse(elem: *Element, parent_extnumber: ?u31) !?@This() {
        // check for either _SPEC_VERSION or _EXTENSION_NAME
        const extends = elem.getAttribute("extends") orelse return null;

        if (elem.getAttribute("offset")) |offset_str| {
            const offset = try std.fmt.parseInt(u31, offset_str, 10);
            const name = elem.getAttribute("name") orelse return error.InvalidRegistry;
            const extnumber = if (elem.getAttribute("extnumber")) |num|
                try std.fmt.parseInt(u31, num, 10)
            else
                null;

            const actual_extnumber = extnumber orelse parent_extnumber orelse return error.InvalidRegistry;
            const value = blk: {
                const abs_value = enumExtOffsetToValue(actual_extnumber, offset);
                if (elem.getAttribute("dir")) |dir| {
                    if (std.mem.eql(u8, dir, "-")) {
                        break :blk -@as(i32, abs_value);
                    } else {
                        return error.InvalidRegistry;
                    }
                }

                break :blk @as(i32, abs_value);
            };

            return @This(){
                .extends = extends,
                .extnumber = actual_extnumber,
                .field = .{ .name = name, .value = .{ .int = value } },
            };
        }

        return @This(){
            .extends = extends,
            .extnumber = parent_extnumber,
            .field = try Enum.Field.parse(elem),
        };
    }

    fn enumExtOffsetToValue(extnumber: u31, offset: u31) u31 {
        const extension_value_base = 1000000000;
        const extension_block = 1000;
        return extension_value_base + (extnumber - 1) * extension_block + offset;
    }
};

extends: []EnumExtension,
types: []const []const u8,
commands: []const []const u8,
required_feature_level: ?FeatureLevel,
required_extension: ?[]const u8,

pub fn parse(allocator: std.mem.Allocator, require: *Element, extnumber: ?u31) !@This() {
    var n_extends: usize = 0;
    var n_types: usize = 0;
    var n_commands: usize = 0;

    var it = require.elements();
    while (it.next()) |elem| {
        if (std.mem.eql(u8, elem.tag, "enum")) {
            n_extends += 1;
        } else if (std.mem.eql(u8, elem.tag, "type")) {
            n_types += 1;
        } else if (std.mem.eql(u8, elem.tag, "command")) {
            n_commands += 1;
        }
    }

    const extends = try allocator.alloc(EnumExtension, n_extends);
    const types = try allocator.alloc([]const u8, n_types);
    const commands = try allocator.alloc([]const u8, n_commands);

    var i_extends: usize = 0;
    var i_types: usize = 0;
    var i_commands: usize = 0;

    it = require.elements();
    while (it.next()) |elem| {
        if (std.mem.eql(u8, elem.tag, "enum")) {
            if (try EnumExtension.parse(elem, extnumber)) |ext| {
                extends[i_extends] = ext;
                i_extends += 1;
            }
        } else if (std.mem.eql(u8, elem.tag, "type")) {
            types[i_types] = elem.getAttribute("name") orelse return error.InvalidRegistry;
            i_types += 1;
        } else if (std.mem.eql(u8, elem.tag, "command")) {
            commands[i_commands] = elem.getAttribute("name") orelse return error.InvalidRegistry;
            i_commands += 1;
        }
    }

    const required_feature_level = blk: {
        const feature_level = require.getAttribute("feature") orelse break :blk null;
        if (!std.mem.startsWith(u8, feature_level, "XR_VERSION_")) {
            return error.InvalidRegistry;
        }

        break :blk try FeatureLevel.splitFeatureLevel(feature_level["XR_VERSION_".len..], "_");
    };

    return @This(){
        .extends = extends[0..i_extends],
        .types = types[0..i_types],
        .commands = commands[0..i_commands],
        .required_feature_level = required_feature_level,
        .required_extension = require.getAttribute("extension"),
    };
}
