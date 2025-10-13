const std = @import("std");
const xml = @import("xml.zig");
const XmlCTokenizer = @import("XmlCTokenizer.zig");

pub const api_constants_name = "API Constants";

pub const Value = union(enum) {
    expr: []const u8,
    version: [3][]const u8,
};

name: []const u8,
value: Value,

pub fn parse(allocator: std.mem.Allocator, root: *xml.Element) ![]@This() {
    const enums = blk: {
        var it = root.findChildrenByTag("enums");
        while (it.next()) |child| {
            const name = child.getAttribute("name") orelse continue;
            if (std.mem.eql(u8, name, api_constants_name)) {
                break :blk child;
            }
        }

        return error.InvalidRegistry;
    };

    const types = root.findChildByTag("types") orelse return error.InvalidRegistry;
    const n_defines = blk: {
        var n_defines: usize = 0;
        var it = types.findChildrenByTag("type");
        while (it.next()) |ty| {
            if (ty.getAttribute("category")) |category| {
                if (std.mem.eql(u8, category, "define")) {
                    n_defines += 1;
                }
            }
        }
        break :blk n_defines;
    };

    const extensions = root.findChildByTag("extensions") orelse return error.InvalidRegistry;
    const n_extension_defines = blk: {
        var n_extension_defines: usize = 0;
        var it = extensions.findChildrenByTag("extension");
        while (it.next()) |ext| {
            const require = ext.findChildByTag("require") orelse return error.InvalidRegistry;
            var defines = require.findChildrenByTag("enum");
            while (defines.next()) |e| {
                if (e.getAttribute("offset") != null and e.getAttribute("extends") != null) continue;

                const name = e.getAttribute("name") orelse continue;
                if (std.mem.endsWith(u8, name, "SPEC_VERSION")) continue;
                if (std.mem.endsWith(u8, name, "EXTENSION_NAME")) continue;

                n_extension_defines += 1;
            }
        }
        break :blk n_extension_defines;
    };

    const constants = try allocator.alloc(@This(), enums.children.len + n_defines + n_extension_defines);

    var i: usize = 0;
    var it = enums.findChildrenByTag("enum");
    while (it.next()) |constant| {
        const expr = if (constant.getAttribute("value")) |expr|
            expr
        else if (constant.getAttribute("alias")) |alias|
            alias
        else
            return error.InvalidRegistry;

        constants[i] = .{
            .name = constant.getAttribute("name") orelse return error.InvalidRegistry,
            .value = .{ .expr = expr },
        };

        i += 1;
    }

    i += try parseDefines(types, constants[i..]);
    i += try parseExtensionDefines(extensions, constants[i..]);
    return constants[0..i];
}

fn parseDefines(types: *xml.Element, out: []@This()) !usize {
    var i: usize = 0;
    var it = types.findChildrenByTag("type");
    while (it.next()) |ty| {
        const category = ty.getAttribute("category") orelse continue;
        if (!std.mem.eql(u8, category, "define")) {
            continue;
        }

        const name = ty.getCharData("name") orelse continue;
        if (std.mem.eql(u8, name, "XR_CURRENT_API_VERSION")) {
            var xctok = XmlCTokenizer.init(ty);
            out[i] = .{
                .name = name,
                .value = .{ .version = xctok.parseVersion() catch continue },
            };
        } else {
            const expr = std.mem.trim(u8, ty.children[2].char_data, " ");

            // TODO this doesn't work with all #defines yet (need to handle hex, U/L suffix, etc.)
            _ = std.fmt.parseInt(i32, expr, 10) catch continue;

            out[i] = .{
                .name = name,
                .value = .{ .expr = expr },
            };
        }
        i += 1;
    }

    return i;
}

fn parseExtensionDefines(extensions: *xml.Element, out: []@This()) !usize {
    var i: usize = 0;
    var it = extensions.findChildrenByTag("extension");

    while (it.next()) |ext| {
        const require = ext.findChildByTag("require") orelse return error.InvalidRegistry;
        var defines = require.findChildrenByTag("enum");
        while (defines.next()) |e| {
            if (e.getAttribute("offset") != null and e.getAttribute("extends") != null) continue;

            const name = e.getAttribute("name") orelse continue;
            if (std.mem.endsWith(u8, name, "SPEC_VERSION")) continue;
            if (std.mem.endsWith(u8, name, "EXTENSION_NAME")) continue;

            out[i] = .{
                .name = name,
                .value = .{ .expr = e.getAttribute("value") orelse continue },
            };

            i += 1;
        }
    }

    return i;
}
