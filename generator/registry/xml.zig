const std = @import("std");

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const Content = union(enum) {
    char_data: []const u8,
    comment: []const u8,
    element: *Element,
};

pub const Element = struct {
    tag: []const u8,
    attributes: []Attribute = &.{},
    children: []Content = &.{},

    line: usize,
    column: usize,

    pub fn getAttribute(self: Element, attrib_name: []const u8) ?[]const u8 {
        for (self.attributes) |child| {
            if (std.mem.eql(u8, child.name, attrib_name)) {
                return child.value;
            }
        }

        return null;
    }

    pub fn getCharData(self: Element, child_tag: []const u8) ?[]const u8 {
        const child = self.findChildByTag(child_tag) orelse return null;
        if (child.children.len != 1) {
            return null;
        }

        return switch (child.children[0]) {
            .char_data => |char_data| char_data,
            else => null,
        };
    }

    pub fn iterator(self: Element) ChildIterator {
        return .{
            .items = self.children,
            .i = 0,
        };
    }

    pub fn elements(self: Element) ChildElementIterator {
        return .{
            .inner = self.iterator(),
        };
    }

    pub fn findChildByTag(self: Element, tag: []const u8) ?*Element {
        var it = self.findChildrenByTag(tag);
        return it.next();
    }

    pub fn findChildrenByTag(self: Element, tag: []const u8) FindChildrenByTagIterator {
        return .{
            .inner = self.elements(),
            .tag = tag,
        };
    }

    pub const ChildIterator = struct {
        items: []Content,
        i: usize,

        pub fn next(self: *ChildIterator) ?*Content {
            if (self.i < self.items.len) {
                self.i += 1;
                return &self.items[self.i - 1];
            }

            return null;
        }
    };

    pub const ChildElementIterator = struct {
        inner: ChildIterator,

        pub fn next(self: *ChildElementIterator) ?*Element {
            while (self.inner.next()) |child| {
                if (child.* != .element) {
                    continue;
                }

                return child.*.element;
            }

            return null;
        }
    };

    pub const FindChildrenByTagIterator = struct {
        inner: ChildElementIterator,
        tag: []const u8,

        pub fn next(self: *FindChildrenByTagIterator) ?*Element {
            while (self.inner.next()) |child| {
                if (!std.mem.eql(u8, child.tag, self.tag)) {
                    continue;
                }

                return child;
            }

            return null;
        }
    };
};

pub const Document = struct {
    xml_decl: ?*Element,
    root: *Element,
};

pub const Parser = struct {
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

    pub fn parse(self: *@This()) !Document {
        var doc = Document{
            .xml_decl = null,
            .root = undefined,
        };

        try skipComments(self);

        doc.xml_decl = try self.parseElement(.xml_decl);
        _ = self.eatWs();
        _ = self.eatStr("<!DOCTYPE xml>");
        _ = self.eatWs();

        // xr.xml currently has 2 processing instruction tags, they're handled manually for now
        _ = try self.parseElement(.xml_decl);
        _ = self.eatWs();
        _ = try self.parseElement(.xml_decl);
        _ = self.eatWs();

        try self.skipComments();

        doc.root = (try self.parseElement(.element)) orelse return error.InvalidDocument;
        _ = self.eatWs();
        try self.skipComments();

        if (self.peek() != null) return error.InvalidDocument;

        return doc;
    }

    fn skipComments(self: *@This()) !void {
        while ((try self.parseComment()) != null) {
            _ = self.eatWs();
        }
    }

    fn parseComment(self: *@This()) !?[]const u8 {
        if (!self.eatStr("<!--")) return null;

        const begin = self.offset;
        while (!self.eatStr("-->")) {
            _ = self.consume() catch return error.UnclosedComment;
        }

        const end = self.offset - "-->".len;
        return try self.allocator.dupe(u8, self.source[begin..end]);
    }

    fn parseElement(self: *@This(), comptime kind: ElementKind) !?*Element {
        const start = self.offset;

        switch (kind) {
            .xml_decl => {
                if (!self.eatStr("<?")) return null;
            },
            .element => {
                if (!self.eat('<')) return null;
            },
        }

        const tag = parseNameNoDupe(self) catch {
            self.offset = start;
            return null;
        };

        var attributes = std.array_list.Managed(Attribute).init(self.allocator);
        defer attributes.deinit();

        var children = std.array_list.Managed(Content).init(self.allocator);
        defer children.deinit();

        while (self.eatWs()) {
            const attr = (try self.parseAttr()) orelse break;
            try attributes.append(attr);
        }

        switch (kind) {
            .xml_decl => try self.expectStr("?>"),
            .element => {
                if (!self.eatStr("/>")) {
                    try self.expect('>');

                    while (true) {
                        if (self.peek() == null) {
                            return error.UnexpectedEof;
                        } else if (self.eatStr("</")) {
                            break;
                        }

                        const content = try self.parseContent();
                        try children.append(content);
                    }

                    const closing_tag = try parseNameNoDupe(self);
                    if (!std.mem.eql(u8, tag.slice, closing_tag.slice)) {
                        return error.NonMatchingClosingTag;
                    }

                    _ = self.eatWs();
                    try self.expect('>');
                }
            },
        }

        const element = try self.allocator.create(Element);
        element.* = .{
            .tag = try self.allocator.dupe(u8, tag.slice),
            .attributes = try attributes.toOwnedSlice(),
            .children = try children.toOwnedSlice(),
            .line = tag.line,
            .column = tag.column,
        };
        return element;
    }

    fn parseContent(self: *@This()) ParseError!Content {
        if (try self.parseCharData()) |cd| {
            return Content{ .char_data = cd };
        } else if (try self.parseComment()) |comment| {
            return Content{ .comment = comment };
        } else if (try self.parseElement(.element)) |elem| {
            return Content{ .element = elem };
        } else {
            return error.UnexpectedCharacter;
        }
    }

    fn parseCharData(self: *@This()) !?[]const u8 {
        const begin = self.offset;

        while (self.peek()) |ch| {
            switch (ch) {
                '<' => break,
                else => _ = self.consumeNoEof(),
            }
        }

        const end = self.offset;
        if (begin == end) return null;

        return try unescape(self.allocator, self.source[begin..end]);
    }

    fn parseAttr(self: *@This()) !?Attribute {
        const name = parseNameNoDupe(self) catch return null;
        _ = self.eatWs();
        try self.expect('=');
        _ = self.eatWs();
        const value = try self.parseAttrValue();

        const attr = Attribute{
            .name = try self.allocator.dupe(u8, name.slice),
            .value = value,
        };
        return attr;
    }

    fn parseAttrValue(self: *@This()) ![]const u8 {
        const quote = try self.consume();
        if (quote != '"' and quote != '\'') return error.UnexpectedCharacter;

        const begin = self.offset;

        while (true) {
            const c = self.consume() catch return error.UnclosedValue;
            if (c == quote) break;
        }

        const end = self.offset - 1;

        return try unescape(self.allocator, self.source[begin..end]);
    }

    fn parseEqAttrValue(self: *@This()) ![]const u8 {
        _ = self.eatWs();
        try self.expect('=');
        _ = self.eatWs();

        return try self.parseAttrValue();
    }

    fn peek(self: *@This()) ?u8 {
        return if (self.offset < self.source.len) self.source[self.offset] else null;
    }

    fn consume(self: *@This()) !u8 {
        if (self.offset < self.source.len) {
            return self.consumeNoEof();
        }

        return error.UnexpectedEof;
    }

    fn consumeNoEof(self: *@This()) u8 {
        std.debug.assert(self.offset < self.source.len);
        const c = self.source[self.offset];
        self.offset += 1;

        if (c == '\n') {
            self.line += 1;
            self.column = 0;
        } else {
            self.column += 1;
        }

        return c;
    }

    fn eat(self: *@This(), char: u8) bool {
        self.expect(char) catch return false;
        return true;
    }

    fn expect(self: *@This(), expected: u8) !void {
        if (self.peek()) |actual| {
            if (expected != actual) {
                return error.UnexpectedCharacter;
            }

            _ = self.consumeNoEof();
            return;
        }

        return error.UnexpectedEof;
    }

    fn eatStr(self: *@This(), text: []const u8) bool {
        self.expectStr(text) catch return false;
        return true;
    }

    fn expectStr(self: *@This(), text: []const u8) !void {
        if (self.source.len < self.offset + text.len) {
            return error.UnexpectedEof;
        } else if (std.mem.startsWith(u8, self.source[self.offset..], text)) {
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                _ = self.consumeNoEof();
            }

            return;
        }

        return error.UnexpectedCharacter;
    }

    fn eatWs(self: *@This()) bool {
        var ws = false;

        while (self.peek()) |ch| {
            switch (ch) {
                ' ', '\t', '\n', '\r' => {
                    ws = true;
                    _ = self.consumeNoEof();
                },
                else => break,
            }
        }

        return ws;
    }

    fn expectWs(self: *@This()) !void {
        if (!self.eatWs()) return error.UnexpectedCharacter;
    }

    fn currentLine(self: @This()) []const u8 {
        var begin: usize = 0;
        if (std.mem.lastIndexOfScalar(u8, self.source[0..self.offset], '\n')) |prev_nl| {
            begin = prev_nl + 1;
        }

        const end = std.mem.indexOfScalarPos(u8, self.source, self.offset, '\n') orelse self.source.len;
        return self.source[begin..end];
    }
};

test "xml: Parser" {
    {
        var parser = Parser.init("I like pythons");
        try std.testing.expectEqual(@as(?u8, 'I'), parser.peek());
        try std.testing.expectEqual(@as(u8, 'I'), parser.consumeNoEof());
        try std.testing.expectEqual(@as(?u8, ' '), parser.peek());
        try std.testing.expectEqual(@as(u8, ' '), try parser.consume());

        try std.testing.expect(parser.eat('l'));
        try std.testing.expectEqual(@as(?u8, 'i'), parser.peek());
        try std.testing.expectEqual(false, parser.eat('a'));
        try std.testing.expectEqual(@as(?u8, 'i'), parser.peek());

        try parser.expect('i');
        try std.testing.expectEqual(@as(?u8, 'k'), parser.peek());
        try std.testing.expectError(error.UnexpectedCharacter, parser.expect('a'));
        try std.testing.expectEqual(@as(?u8, 'k'), parser.peek());

        try std.testing.expect(parser.eatStr("ke"));
        try std.testing.expectEqual(@as(?u8, ' '), parser.peek());

        try std.testing.expect(parser.eatWs());
        try std.testing.expectEqual(@as(?u8, 'p'), parser.peek());
        try std.testing.expectEqual(false, parser.eatWs());
        try std.testing.expectEqual(@as(?u8, 'p'), parser.peek());

        try std.testing.expectEqual(false, parser.eatStr("aaaaaaaaa"));
        try std.testing.expectEqual(@as(?u8, 'p'), parser.peek());

        try std.testing.expectError(error.UnexpectedEof, parser.expectStr("aaaaaaaaa"));
        try std.testing.expectEqual(@as(?u8, 'p'), parser.peek());
        try std.testing.expectError(error.UnexpectedCharacter, parser.expectStr("pytn"));
        try std.testing.expectEqual(@as(?u8, 'p'), parser.peek());
        try parser.expectStr("python");
        try std.testing.expectEqual(@as(?u8, 's'), parser.peek());
    }

    {
        var parser = Parser.init("");
        try std.testing.expectEqual(parser.peek(), null);
        try std.testing.expectError(error.UnexpectedEof, parser.consume());
        try std.testing.expectEqual(parser.eat('p'), false);
        try std.testing.expectError(error.UnexpectedEof, parser.expect('p'));
    }
}

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

const Token = struct {
    line: usize,
    column: usize,
    slice: []const u8,
};
fn parseNameNoDupe(parser: *Parser) !Token {
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

const ElementKind = enum {
    xml_decl,
    element,
};

test "xml: parseElement" {
    {
        var parser = Parser.init("<= a='b'/>");
        try std.testing.expectEqual(@as(?*Element, null), try parser.parseElement(.element));
        try std.testing.expectEqual(@as(?u8, '<'), parser.peek());
    }

    {
        var parser = Parser.init("<python size='15' color = \"green\"/>");
        const elem = try parser.parseElement(.element);
        try std.testing.expectEqualSlices(u8, elem.?.tag, "python");

        const size_attr = elem.?.attributes[0];
        try std.testing.expectEqualSlices(u8, size_attr.name, "size");
        try std.testing.expectEqualSlices(u8, size_attr.value, "15");

        const color_attr = elem.?.attributes[1];
        try std.testing.expectEqualSlices(u8, color_attr.name, "color");
        try std.testing.expectEqualSlices(u8, color_attr.value, "green");
    }

    {
        var parser = Parser.init("<python>test</python>");
        const elem = try parser.parseElement(.element);
        try std.testing.expectEqualSlices(u8, elem.?.tag, "python");
        try std.testing.expectEqualSlices(u8, elem.?.children[0].char_data, "test");
    }

    {
        var parser = Parser.init("<a>b<c/>d<e/>f<!--g--></a>");
        const elem = try parser.parseElement(.element);
        try std.testing.expectEqualSlices(u8, elem.?.tag, "a");
        try std.testing.expectEqualSlices(u8, elem.?.children[0].char_data, "b");
        try std.testing.expectEqualSlices(u8, elem.?.children[1].element.tag, "c");
        try std.testing.expectEqualSlices(u8, elem.?.children[2].char_data, "d");
        try std.testing.expectEqualSlices(u8, elem.?.children[3].element.tag, "e");
        try std.testing.expectEqualSlices(u8, elem.?.children[4].char_data, "f");
        try std.testing.expectEqualSlices(u8, elem.?.children[5].comment, "g");
    }
}

test "xml: parse prolog" {
    {
        var parser = Parser.init(std.testing.allocator, "<?xmla version='aa'?>");
        const decl = try parser.parseElement(.xml_decl);
        try std.testing.expectEqualSlices(u8, decl.?.tag, "xmla");
        try std.testing.expectEqualSlices(u8, "aa", decl.?.getAttribute("version").?);
    }

    {
        var parser = Parser.init("<?xml version='aa'?>");
        const decl = try parser.parseElement(.xml_decl);
        try std.testing.expectEqualSlices(u8, "aa", decl.?.getAttribute("version").?);
        try std.testing.expectEqual(@as(?[]const u8, null), decl.?.getAttribute("encoding"));
        try std.testing.expectEqual(@as(?[]const u8, null), decl.?.getAttribute("standalone"));
    }

    {
        var parser = Parser.init("<?xml version=\"ccc\" encoding = 'bbb' standalone   \t =   'yes'?>");
        const decl = try parser.parseElement(.xml_decl);
        try std.testing.expectEqualSlices(u8, "ccc", decl.?.getAttribute("version").?);
        try std.testing.expectEqualSlices(u8, "bbb", decl.?.getAttribute("encoding").?);
        try std.testing.expectEqualSlices(u8, "yes", decl.?.getAttribute("standalone").?);
    }
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

fn unescape(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
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

test "xml: unescape" {
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

test "xml: top level comments" {
    var parser = Parser.init(
        std.testing.allocator,
        "<?xml version='aa'?><!--comment--><python color='green'/><!--another comment-->",
    );
    const doc = try parser.parse();
    try std.testing.expectEqualSlices(u8, "python", doc.root.tag);
}
