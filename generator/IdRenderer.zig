const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Registry = @import("registry/Registry.zig");

pub const Error = std.io.Writer.Error || error{WriteFailed} || error{OutOfMemory};

pub fn isZigPrimitiveType(name: []const u8) bool {
    if (name.len > 1 and (name[0] == 'u' or name[0] == 'i')) {
        for (name[1..]) |c| {
            switch (c) {
                '0'...'9' => {},
                else => break,
            }
        } else return true;
    }

    const primitives = [_][]const u8{
        "void",
        "comptime_float",
        "comptime_int",
        "bool",
        "isize",
        "usize",
        "f16",
        "f32",
        "f64",
        "f128",
        "noreturn",
        "type",
        "anyerror",
        "c_short",
        "c_ushort",
        "c_int",
        "c_uint",
        "c_long",
        "c_ulong",
        "c_longlong",
        "c_ulonglong",
        "c_longdouble",
        // Removed in stage 2 in https://github.com/ziglang/zig/commit/05cf44933d753f7a5a53ab289ea60fd43761de57,
        // but these are still invalid identifiers in stage 1.
        "undefined",
        "true",
        "false",
        "null",
    };

    for (primitives) |reserved| {
        if (mem.eql(u8, reserved, name)) {
            return true;
        }
    }

    return false;
}

pub fn writeIdentifier(writer: *std.io.Writer, id: []const u8) Error!void {
    // https://github.com/ziglang/zig/issues/2897
    if (isZigPrimitiveType(id)) {
        try writer.print("@\"{f}\"", .{std.zig.fmtString(id)});
    } else {
        try writer.print("{f}", .{std.zig.fmtId(id)});
    }
}

pub const CaseStyle = enum {
    snake,
    screaming_snake,
    title,
    camel,
};

pub const SegmentIterator = struct {
    text: []const u8,
    offset: usize,

    pub fn init(text: []const u8) SegmentIterator {
        return .{
            .text = text,
            .offset = 0,
        };
    }

    fn nextBoundary(this: SegmentIterator) usize {
        var i = this.offset + 1;

        while (true) {
            if (i == this.text.len or this.text[i] == '_') {
                return i;
            }

            const prev_lower = std.ascii.isLower(this.text[i - 1]);
            const next_lower = std.ascii.isLower(this.text[i]);

            if (prev_lower and !next_lower) {
                return i;
            } else if (i != this.offset + 1 and !prev_lower and next_lower) {
                return i - 1;
            }

            i += 1;
        }
    }

    pub fn next(this: *SegmentIterator) ?[]const u8 {
        while (this.offset < this.text.len and this.text[this.offset] == '_') {
            this.offset += 1;
        }

        if (this.offset == this.text.len) {
            return null;
        }

        const end = this.nextBoundary();
        const word = this.text[this.offset..end];
        this.offset = end;
        return word;
    }

    pub fn rest(this: SegmentIterator) []const u8 {
        if (this.offset >= this.text.len) {
            return &[_]u8{};
        } else {
            return this.text[this.offset..];
        }
    }
};

allocator: std.mem.Allocator,
tags: []const []const u8,
text_cache: std.array_list.Managed(u8),

pub fn init(allocator: Allocator, registry_tags: []const Registry.Tag) @This() {
    const tags = allocator.alloc([]const u8, registry_tags.len) catch @panic("OOM");
    for (tags, registry_tags) |*tag, registry_tag| {
        tag.* = registry_tag.name;
    }
    return .{
        .allocator = allocator,
        .tags = tags,
        .text_cache = std.array_list.Managed(u8).init(allocator),
    };
}

pub fn deinit(this: *@This()) void {
    this.allocator.free(this.tags);
    this.text_cache.deinit();
}

fn renderSnake(this: *@This(), screaming: bool, id: []const u8, tag: ?[]const u8) !void {
    var it = SegmentIterator.init(id);
    var first = true;

    while (it.next()) |segment| {
        if (first) {
            first = false;
        } else {
            try this.text_cache.append('_');
        }

        for (segment) |c| {
            try this.text_cache.append(if (screaming) std.ascii.toUpper(c) else std.ascii.toLower(c));
        }
    }

    if (tag) |name| {
        try this.text_cache.append('_');

        for (name) |c| {
            try this.text_cache.append(if (screaming) std.ascii.toUpper(c) else std.ascii.toLower(c));
        }
    }
}

fn renderCamel(this: *@This(), title: bool, id: []const u8, tag: ?[]const u8) !void {
    var it = SegmentIterator.init(id);
    var lower_first = !title;

    while (it.next()) |segment| {
        var i: usize = 0;
        while (i < segment.len and std.ascii.isDigit(segment[i])) {
            try this.text_cache.append(segment[i]);
            i += 1;
        }

        if (i == segment.len) {
            continue;
        }

        if (i == 0 and lower_first) {
            try this.text_cache.append(std.ascii.toLower(segment[i]));
        } else {
            try this.text_cache.append(std.ascii.toUpper(segment[i]));
        }
        lower_first = false;

        for (segment[i + 1 ..]) |c| {
            try this.text_cache.append(std.ascii.toLower(c));
        }
    }

    if (tag) |name| {
        try this.text_cache.appendSlice(name);
    }
}

pub fn renderFmt(
    this: *@This(),
    out: *std.io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    this.text_cache.items.len = 0;
    try std.fmt.format(this.text_cache.writer(), fmt, args);
    try writeIdentifier(out, this.text_cache.items);
}

pub fn renderWithCase(this: *@This(), out: *std.io.Writer, case_style: CaseStyle, id: []const u8) !void {
    const tag = this.getAuthorTag(id);
    // The trailing underscore doesn't need to be removed here as its removed by the SegmentIterator.
    const adjusted_id = if (tag) |name| id[0 .. id.len - name.len] else id;

    this.text_cache.items.len = 0;

    switch (case_style) {
        .snake => try this.renderSnake(false, adjusted_id, tag),
        .screaming_snake => try this.renderSnake(true, adjusted_id, tag),
        .title => try this.renderCamel(true, adjusted_id, tag),
        .camel => try this.renderCamel(false, adjusted_id, tag),
    }

    try writeIdentifier(out, this.text_cache.items);
}

pub fn getAuthorTag(this: @This(), id: []const u8) ?[]const u8 {
    for (this.tags) |tag| {
        if (mem.endsWith(u8, id, tag)) {
            return tag;
        }
    }

    // HACK for EXTX?
    if (mem.endsWith(u8, id, "EXTX")) {
        return "EXTX";
    }

    return null;
}

pub fn stripAuthorTag(this: @This(), id: []const u8) []const u8 {
    if (this.getAuthorTag(id)) |tag| {
        return mem.trimRight(u8, id[0 .. id.len - tag.len], "_");
    }

    return id;
}
