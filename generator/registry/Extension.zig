const std = @import("std");
const xml = @import("xml/xml.zig");
const XmlDocument = xml.XmlDocument;
const Element = XmlDocument.Element;
const FeatureLevel = @import("FeatureLevel.zig");
const Require = @import("Require.zig");

pub const ExtensionType = enum {
    instance,
    device,
};

pub const Promotion = union(enum) {
    none,
    feature: FeatureLevel,
    extension: []const u8,
};

name: []const u8,
number: u31,
version: u32,
extension_type: ?ExtensionType,
depends: []const []const u8, // Other extensions
promoted_to: Promotion,
platform: ?[]const u8,
required_feature_level: ?FeatureLevel,
requires: []Require,

pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("extension: {s}", .{this.name});
}

pub fn parseExtension(allocator: std.mem.Allocator, extension: *Element) !@This() {
    const name = extension.getAttribute("name") orelse return error.InvalidRegistry;
    const platform = extension.getAttribute("platform");
    const version = try findExtVersion(extension);

    // For some reason there are two ways for an extension to state its required
    // feature level: both seperately in each <require> tag, or using
    // the requiresCore attribute.
    const requires_core = if (extension.getAttribute("requiresCore")) |feature_level|
        try FeatureLevel.splitFeatureLevel(feature_level, ".")
    else
        null;

    const promoted_to: Promotion = blk: {
        const promotedto = extension.getAttribute("promotedto") orelse break :blk .none;
        if (std.mem.startsWith(u8, promotedto, "XR_VERSION_")) {
            const feature_level = try FeatureLevel.splitFeatureLevel(promotedto["XR_VERSION_".len..], "_");

            break :blk .{ .feature = feature_level };
        }

        break :blk .{ .extension = promotedto };
    };

    const number = blk: {
        const number_str = extension.getAttribute("number") orelse return error.InvalidRegistry;
        break :blk try std.fmt.parseInt(u31, number_str, 10);
    };

    const ext_type: ?ExtensionType = blk: {
        const ext_type_str = extension.getAttribute("type") orelse break :blk null;
        if (std.mem.eql(u8, ext_type_str, "instance")) {
            break :blk .instance;
        } else if (std.mem.eql(u8, ext_type_str, "device")) {
            break :blk .device;
        } else {
            return error.InvalidRegistry;
        }
    };

    const depends = blk: {
        const requires_str = extension.getAttribute("requires") orelse break :blk &[_][]const u8{};
        break :blk try splitCommaAlloc(allocator, requires_str);
    };

    var requires = try allocator.alloc(Require, extension.children.len);
    var i: usize = 0;
    var it = extension.findChildrenByTag("require");
    while (it.next()) |require| {
        requires[i] = try Require.parse(allocator, require, number);
        i += 1;
    }

    return @This(){
        .name = name,
        .number = number,
        .version = version,
        .extension_type = ext_type,
        .depends = depends,
        .promoted_to = promoted_to,
        .platform = platform,
        .required_feature_level = requires_core,
        .requires = requires[0..i],
    };
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

fn findExtVersion(extension: *Element) !u32 {
    var req_it = extension.findChildrenByTag("require");
    while (req_it.next()) |req| {
        var enum_it = req.findChildrenByTag("enum");
        while (enum_it.next()) |e| {
            const name = e.getAttribute("name") orelse continue;
            const value = e.getAttribute("value") orelse continue;
            if (std.mem.endsWith(u8, name, "_SPEC_VERSION")) {
                return try std.fmt.parseInt(u32, value, 10);
            }
        }
    }

    return error.InvalidRegistry;
}

pub fn parse(allocator: std.mem.Allocator, root: *Element) ![]@This() {
    const extensions_elem = root.findChildByTag("extensions") orelse return error.InvalidRegistry;

    const extensions = try allocator.alloc(@This(), extensions_elem.children.len);
    var i: usize = 0;
    var it = extensions_elem.findChildrenByTag("extension");
    while (it.next()) |extension| {
        // Some extensions (in particular 94) are disabled, so just skip them
        if (extension.getAttribute("supported")) |supported| {
            if (std.mem.eql(u8, supported, "disabled")) {
                continue;
            }
        }

        extensions[i] = try parseExtension(allocator, extension);
        i += 1;
    }

    return extensions[0..i];
}
