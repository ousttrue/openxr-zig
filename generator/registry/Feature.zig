const std = @import("std");
const xml = @import("xml.zig");
const FeatureLevel = @import("FeatureLevel.zig");
const Require = @import("Require.zig");

name: []const u8,
level: FeatureLevel, // from 'number'
requires: []Require,

pub fn parseFeature(allocator: std.mem.Allocator, feature: *xml.Element) !@This() {
    const name = feature.getAttribute("name") orelse return error.InvalidRegistry;
    const feature_level = blk: {
        const number = feature.getAttribute("number") orelse return error.InvalidRegistry;
        break :blk try FeatureLevel.splitFeatureLevel(number, ".");
    };

    var requires = try allocator.alloc(Require, feature.children.len);
    var i: usize = 0;
    var it = feature.findChildrenByTag("require");
    while (it.next()) |require| {
        requires[i] = try Require.parse(allocator, require, null);
        i += 1;
    }

    return @This(){
        .name = name,
        .level = feature_level,
        .requires = requires[0..i],
    };
}

pub fn parse(allocator: std.mem.Allocator, root: *xml.Element) ![]@This() {
    var it = root.findChildrenByTag("feature");
    var count: usize = 0;
    while (it.next()) |_| count += 1;

    const features = try allocator.alloc(@This(), count);
    var i: usize = 0;
    it = root.findChildrenByTag("feature");
    while (it.next()) |feature| {
        features[i] = try parseFeature(allocator, feature);
        i += 1;
    }

    return features;
}
