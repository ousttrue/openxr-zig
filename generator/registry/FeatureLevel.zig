const std = @import("std");

major: u32,
minor: u32,

pub fn splitFeatureLevel(ver: []const u8, split: []const u8) !@This() {
    var it = std.mem.splitSequence(u8, ver, split);

    const major = it.next() orelse return error.InvalidFeatureLevel;
    const minor = it.next() orelse return error.InvalidFeatureLevel;
    if (it.next() != null) {
        return error.InvalidFeatureLevel;
    }

    return @This(){
        .major = try std.fmt.parseInt(u32, major, 10),
        .minor = try std.fmt.parseInt(u32, minor, 10),
    };
}
