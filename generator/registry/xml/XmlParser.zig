const std = @import("std");
const XmlDocument = @import("XmlDocument.zig");
const Element = XmlDocument.Element;
const Attribute = XmlDocument.Attribute;
const Content = XmlDocument.Content;

pub const ParseError = error{
    IllegalCharacter,
    UnexpectedEof,
    UnexpectedCharacter,
    UnclosedValue,
    UnclosedComment,
    InvalidName,
    InvalidEntity,
    InvalidStandaloneValue,
    NonMatchingClosingTag,
    InvalidDocument,
    OutOfMemory,
};

allocator: std.mem.Allocator,
source: []const u8,
offset: usize,
line: usize,
column: usize,

pub fn init(allocator: std.mem.Allocator, source: []const u8) @This() {
    return @This(){
        .allocator = allocator,
        .source = source,
        .offset = 0,
        .line = 0,
        .column = 0,
    };
}

pub fn skipComments(this: *@This()) !void {
    while ((try this.parseComment())) |comment| {
        _ = this.eatWs();
        this.allocator.free(comment);
    }
}

fn parseComment(this: *@This()) !?[]const u8 {
    if (!this.eatStr("<!--")) return null;

    const begin = this.offset;
    while (!this.eatStr("-->")) {
        _ = this.consume() catch return error.UnclosedComment;
    }

    const end = this.offset - "-->".len;
    return try this.allocator.dupe(u8, this.source[begin..end]);
}

const ElementKind = enum {
    xml_decl,
    element,
};

pub fn parseElement(this: *@This(), comptime kind: ElementKind) !?*Element {
    const start = this.offset;

    switch (kind) {
        .xml_decl => {
            if (!this.eatStr("<?")) return null;
        },
        .element => {
            if (!this.eat('<')) return null;
        },
    }

    const tag = parseNameNoDupe(this) catch {
        this.offset = start;
        return null;
    };

    var attributes = std.array_list.Managed(Attribute).init(this.allocator);
    defer attributes.deinit();

    var children = std.array_list.Managed(Content).init(this.allocator);
    defer children.deinit();

    while (this.eatWs()) {
        const attr = (try this.parseAttr()) orelse break;
        try attributes.append(attr);
    }

    switch (kind) {
        .xml_decl => try this.expectStr("?>"),
        .element => {
            if (!this.eatStr("/>")) {
                try this.expect('>');

                while (true) {
                    if (this.peek() == null) {
                        return error.UnexpectedEof;
                    } else if (this.eatStr("</")) {
                        break;
                    }

                    const content = try this.parseContent();
                    try children.append(content);
                }

                const closing_tag = try parseNameNoDupe(this);
                if (!std.mem.eql(u8, tag.slice, closing_tag.slice)) {
                    return error.NonMatchingClosingTag;
                }

                _ = this.eatWs();
                try this.expect('>');
            }
        },
    }

    const element = try this.allocator.create(Element);
    element.* = .{
        .tag = try this.allocator.dupe(u8, tag.slice),
        .attributes = try attributes.toOwnedSlice(),
        .children = try children.toOwnedSlice(),
        .line = tag.line,
        .column = tag.column,
    };
    return element;
}

const Token = struct {
    line: usize,
    column: usize,
    slice: []const u8,
};
fn parseNameNoDupe(parser: *@This()) !Token {
    // XML's spec on names is very long, so to make this easier
    // we just take any character that is not special and not whitespace
    const line = parser.line;
    const column = parser.column;
    const begin = parser.offset;

    while (parser.peek()) |ch| {
        switch (ch) {
            ' ', '\t', '\n', '\r' => break,
            '&', '"', '\'', '<', '>', '?', '=', '/' => break,
            else => _ = parser.consumeNoEof(),
        }
    }

    const end = parser.offset;
    if (begin == end) return error.InvalidName;

    return .{
        .line = line,
        .column = column,
        .slice = parser.source[begin..end],
    };
}

fn parseContent(this: *@This()) ParseError!Content {
    if (try this.parseCharData()) |cd| {
        return Content{ .char_data = cd };
    } else if (try this.parseComment()) |comment| {
        return Content{ .comment = comment };
    } else if (try this.parseElement(.element)) |elem| {
        return Content{ .element = elem };
    } else {
        return error.UnexpectedCharacter;
    }
}

fn parseCharData(this: *@This()) !?[]const u8 {
    const begin = this.offset;

    while (this.peek()) |ch| {
        switch (ch) {
            '<' => break,
            else => _ = this.consumeNoEof(),
        }
    }

    const end = this.offset;
    if (begin == end) return null;

    return try unescape(this.allocator, this.source[begin..end]);
}

fn parseAttr(this: *@This()) !?Attribute {
    const name = parseNameNoDupe(this) catch return null;
    _ = this.eatWs();
    try this.expect('=');
    _ = this.eatWs();
    const value = try this.parseAttrValue();

    const attr = Attribute{
        .name = try this.allocator.dupe(u8, name.slice),
        .value = value,
    };
    return attr;
}

fn parseAttrValue(this: *@This()) ![]const u8 {
    const quote = try this.consume();
    if (quote != '"' and quote != '\'') return error.UnexpectedCharacter;

    const begin = this.offset;

    while (true) {
        const c = this.consume() catch return error.UnclosedValue;
        if (c == quote) break;
    }

    const end = this.offset - 1;

    return try unescape(this.allocator, this.source[begin..end]);
}

fn parseEqAttrValue(this: *@This()) ![]const u8 {
    _ = this.eatWs();
    try this.expect('=');
    _ = this.eatWs();

    return try this.parseAttrValue();
}

pub fn peek(this: *@This()) ?u8 {
    return if (this.offset < this.source.len) this.source[this.offset] else null;
}

pub fn consume(this: *@This()) !u8 {
    if (this.offset < this.source.len) {
        return this.consumeNoEof();
    }

    return error.UnexpectedEof;
}

pub fn consumeNoEof(this: *@This()) u8 {
    std.debug.assert(this.offset < this.source.len);
    const c = this.source[this.offset];
    this.offset += 1;

    if (c == '\n') {
        this.line += 1;
        this.column = 0;
    } else {
        this.column += 1;
    }

    return c;
}

pub fn eat(this: *@This(), char: u8) bool {
    this.expect(char) catch return false;
    return true;
}

pub fn expect(this: *@This(), expected: u8) !void {
    if (this.peek()) |actual| {
        if (expected != actual) {
            return error.UnexpectedCharacter;
        }

        _ = this.consumeNoEof();
        return;
    }

    return error.UnexpectedEof;
}

pub fn eatStr(this: *@This(), text: []const u8) bool {
    this.expectStr(text) catch return false;
    return true;
}

pub fn expectStr(this: *@This(), text: []const u8) !void {
    if (this.source.len < this.offset + text.len) {
        return error.UnexpectedEof;
    } else if (std.mem.startsWith(u8, this.source[this.offset..], text)) {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            _ = this.consumeNoEof();
        }

        return;
    }

    return error.UnexpectedCharacter;
}

pub fn eatWs(this: *@This()) bool {
    var ws = false;

    while (this.peek()) |ch| {
        switch (ch) {
            ' ', '\t', '\n', '\r' => {
                ws = true;
                _ = this.consumeNoEof();
            },
            else => break,
        }
    }

    return ws;
}

pub fn expectWs(this: *@This()) !void {
    if (!this.eatWs()) return error.UnexpectedCharacter;
}

pub fn currentLine(this: @This()) []const u8 {
    var begin: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, this.source[0..this.offset], '\n')) |prev_nl| {
        begin = prev_nl + 1;
    }

    const end = std.mem.indexOfScalarPos(u8, this.source, this.offset, '\n') orelse this.source.len;
    return this.source[begin..end];
}

pub fn unescape(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const unescaped = try allocator.alloc(u8, text.len);

    var j: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (j += 1) {
        if (text[i] == '&') {
            const entity_end = 1 + (std.mem.indexOfScalarPos(u8, text, i, ';') orelse return error.InvalidEntity);
            unescaped[j] = try unescapeEntity(text[i..entity_end]);
            i = entity_end;
        } else {
            unescaped[j] = text[i];
            i += 1;
        }
    }

    return unescaped[0..j];
}

test "unescape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualSlices(u8, "test", try unescape(a, "test"));
    try std.testing.expectEqualSlices(u8, "a<b&c>d\"e'f<", try unescape(a, "a&lt;b&amp;c&gt;d&quot;e&apos;f&lt;"));
    try std.testing.expectError(error.InvalidEntity, unescape(a, "python&"));
    try std.testing.expectError(error.InvalidEntity, unescape(a, "python&&"));
    try std.testing.expectError(error.InvalidEntity, unescape(a, "python&test;"));
    try std.testing.expectError(error.InvalidEntity, unescape(a, "python&boa"));
}

fn unescapeEntity(text: []const u8) !u8 {
    const EntitySubstition = struct { text: []const u8, replacement: u8 };

    const entities = [_]EntitySubstition{
        .{ .text = "&lt;", .replacement = '<' },
        .{ .text = "&gt;", .replacement = '>' },
        .{ .text = "&amp;", .replacement = '&' },
        .{ .text = "&apos;", .replacement = '\'' },
        .{ .text = "&quot;", .replacement = '"' },
    };

    for (entities) |entity| {
        if (std.mem.eql(u8, text, entity.text)) return entity.replacement;
    }

    return error.InvalidEntity;
}
