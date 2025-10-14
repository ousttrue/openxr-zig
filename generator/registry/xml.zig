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

    fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(this.tag);
        for (this.children) |child| {
            switch (child) {
                .char_data => |char_data| {
                    allocator.free(char_data);
                },
                .comment => |comment| {
                    allocator.free(comment);
                },
                .element => |element| {
                    element.deinit(allocator);
                    allocator.destroy(element);
                },
            }
        }
        allocator.free(this.children);

        for (this.attributes) |attribute| {
            allocator.free(attribute.name);
            allocator.free(attribute.value);
        }
        allocator.free(this.attributes);
    }

    pub fn destroy(this: *@This(), allocator: std.mem.Allocator) void {
        this.deinit(allocator);
        allocator.destroy(this);
    }

    pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("<{s} {}:{}", .{ this.tag, this.line, this.column });
        for (this.attributes) |a| {
            try writer.print(" {s}={s}", .{ a.name, a.value });
        }
        try writer.print(">", .{});
        for (this.children) |c| {
            switch (c) {
                .char_data => |char_data| try writer.print("{s}", .{char_data}),
                .comment => |comment| try writer.print("{s}", .{comment}),
                .element => |element| {
                    _ = element;
                    // try writer.print("{f}", .{element});
                },
            }
        }
    }

    pub fn getAttribute(this: Element, attrib_name: []const u8) ?[]const u8 {
        for (this.attributes) |child| {
            if (std.mem.eql(u8, child.name, attrib_name)) {
                return child.value;
            }
        }

        return null;
    }

    pub fn getCharData(this: Element, child_tag: []const u8) ?[]const u8 {
        const child = this.findChildByTag(child_tag) orelse return null;
        if (child.children.len != 1) {
            return null;
        }

        return switch (child.children[0]) {
            .char_data => |char_data| char_data,
            else => null,
        };
    }

    pub fn iterator(this: Element) ChildIterator {
        return .{
            .items = this.children,
            .i = 0,
        };
    }

    pub fn elements(this: Element) ChildElementIterator {
        return .{
            .inner = this.iterator(),
        };
    }

    pub fn findChildByTag(this: Element, tag: []const u8) ?*Element {
        var it = this.findChildrenByTag(tag);
        return it.next();
    }

    pub fn findChildrenByTag(this: Element, tag: []const u8) FindChildrenByTagIterator {
        return .{
            .inner = this.elements(),
            .tag = tag,
        };
    }

    pub const ChildIterator = struct {
        items: []Content,
        i: usize,

        pub fn next(this: *ChildIterator) ?*Content {
            if (this.i < this.items.len) {
                this.i += 1;
                return &this.items[this.i - 1];
            }

            return null;
        }
    };

    pub const ChildElementIterator = struct {
        inner: ChildIterator,

        pub fn next(this: *ChildElementIterator) ?*Element {
            while (this.inner.next()) |child| {
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

        pub fn next(this: *FindChildrenByTagIterator) ?*Element {
            while (this.inner.next()) |child| {
                if (!std.mem.eql(u8, child.tag, this.tag)) {
                    continue;
                }

                return child;
            }

            return null;
        }
    };
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    xml_decl: ?*Element,
    root: *Element,

    pub fn deinit(this: *@This()) void {
        if (this.xml_decl) |xml_decl| {
            xml_decl.deinit(this.allocator);
            this.allocator.destroy(xml_decl);
        }
        this.root.deinit(this.allocator);
        this.allocator.destroy(this.root);
    }
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

    pub fn parse(this: *@This()) !Document {
        var doc = Document{
            .allocator = this.allocator,
            .xml_decl = null,
            .root = undefined,
        };

        try skipComments(this);

        doc.xml_decl = try this.parseElement(.xml_decl);
        _ = this.eatWs();
        _ = this.eatStr("<!DOCTYPE xml>");
        _ = this.eatWs();

        // xr.xml currently has 2 processing instruction tags, they're handled manually for now
        _ = try this.parseElement(.xml_decl);
        _ = this.eatWs();
        _ = try this.parseElement(.xml_decl);
        _ = this.eatWs();

        try this.skipComments();

        doc.root = (try this.parseElement(.element)) orelse return error.InvalidDocument;
        _ = this.eatWs();
        try this.skipComments();

        if (this.peek() != null) return error.InvalidDocument;

        return doc;
    }

    fn skipComments(this: *@This()) !void {
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

    fn parseElement(this: *@This(), comptime kind: ElementKind) !?*Element {
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

    fn peek(this: *@This()) ?u8 {
        return if (this.offset < this.source.len) this.source[this.offset] else null;
    }

    fn consume(this: *@This()) !u8 {
        if (this.offset < this.source.len) {
            return this.consumeNoEof();
        }

        return error.UnexpectedEof;
    }

    fn consumeNoEof(this: *@This()) u8 {
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

    fn eat(this: *@This(), char: u8) bool {
        this.expect(char) catch return false;
        return true;
    }

    fn expect(this: *@This(), expected: u8) !void {
        if (this.peek()) |actual| {
            if (expected != actual) {
                return error.UnexpectedCharacter;
            }

            _ = this.consumeNoEof();
            return;
        }

        return error.UnexpectedEof;
    }

    fn eatStr(this: *@This(), text: []const u8) bool {
        this.expectStr(text) catch return false;
        return true;
    }

    fn expectStr(this: *@This(), text: []const u8) !void {
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

    fn eatWs(this: *@This()) bool {
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

    fn expectWs(this: *@This()) !void {
        if (!this.eatWs()) return error.UnexpectedCharacter;
    }

    fn currentLine(this: @This()) []const u8 {
        var begin: usize = 0;
        if (std.mem.lastIndexOfScalar(u8, this.source[0..this.offset], '\n')) |prev_nl| {
            begin = prev_nl + 1;
        }

        const end = std.mem.indexOfScalarPos(u8, this.source, this.offset, '\n') orelse this.source.len;
        return this.source[begin..end];
    }
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !Document {
    var parser = Parser.init(allocator, src);
    return try parser.parse();
}

test "xml: Parser" {
    {
        var parser = Parser.init(std.testing.allocator, "I like pythons");
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
        var parser = Parser.init(std.testing.allocator, "");
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
    const a = std.testing.allocator;
    {
        var parser = Parser.init(std.testing.allocator, "<= a='b'/>");
        const elem = try parser.parseElement(.element);
        try std.testing.expectEqual(@as(?*Element, null), elem);
        try std.testing.expectEqual(@as(?u8, '<'), parser.peek());
    }

    {
        var parser = Parser.init(std.testing.allocator, "<python size='15' color = \"green\"/>");
        const elem = (try parser.parseElement(.element)).?;
        defer elem.destroy(a);
        try std.testing.expectEqualSlices(u8, elem.tag, "python");

        const size_attr = elem.attributes[0];
        try std.testing.expectEqualSlices(u8, size_attr.name, "size");
        try std.testing.expectEqualSlices(u8, size_attr.value, "15");

        const color_attr = elem.attributes[1];
        try std.testing.expectEqualSlices(u8, color_attr.name, "color");
        try std.testing.expectEqualSlices(u8, color_attr.value, "green");
    }

    {
        var parser = Parser.init(std.testing.allocator, "<python>test</python>");
        const elem = (try parser.parseElement(.element)).?;
        defer elem.destroy(a);
        try std.testing.expectEqualSlices(u8, elem.tag, "python");
        try std.testing.expectEqualSlices(u8, elem.children[0].char_data, "test");
    }

    {
        var parser = Parser.init(a, "<a>b<c/>d<e/>f<!--g--></a>");
        const elem = (try parser.parseElement(.element)).?;
        defer elem.destroy(a);
        try std.testing.expectEqualSlices(u8, elem.tag, "a");
        try std.testing.expectEqualSlices(u8, elem.children[0].char_data, "b");
        try std.testing.expectEqualSlices(u8, elem.children[1].element.tag, "c");
        try std.testing.expectEqualSlices(u8, elem.children[2].char_data, "d");
        try std.testing.expectEqualSlices(u8, elem.children[3].element.tag, "e");
        try std.testing.expectEqualSlices(u8, elem.children[4].char_data, "f");
        try std.testing.expectEqualSlices(u8, elem.children[5].comment, "g");
    }
}

test "xml: parse prolog" {
    const a = std.testing.allocator;

    {
        var parser = Parser.init(a, "<?xmla version='aa'?>");
        const decl = (try parser.parseElement(.xml_decl)).?;
        defer decl.destroy(a);
        try std.testing.expectEqualSlices(u8, decl.tag, "xmla");
        try std.testing.expectEqualSlices(u8, "aa", decl.getAttribute("version").?);
    }

    {
        var parser = Parser.init(a, "<?xml version='aa'?>");
        const decl = (try parser.parseElement(.xml_decl)).?;
        defer decl.destroy(a);
        try std.testing.expectEqualSlices(u8, "aa", decl.getAttribute("version").?);
        try std.testing.expectEqual(@as(?[]const u8, null), decl.getAttribute("encoding"));
        try std.testing.expectEqual(@as(?[]const u8, null), decl.getAttribute("standalone"));
    }

    {
        var parser = Parser.init(a, "<?xml version=\"ccc\" encoding = 'bbb' standalone   \t =   'yes'?>");
        const decl = (try parser.parseElement(.xml_decl)).?;
        defer decl.destroy(a);
        try std.testing.expectEqualSlices(u8, "ccc", decl.getAttribute("version").?);
        try std.testing.expectEqualSlices(u8, "bbb", decl.getAttribute("encoding").?);
        try std.testing.expectEqualSlices(u8, "yes", decl.getAttribute("standalone").?);
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

    var doc = try parser.parse();
    defer doc.deinit();
    try std.testing.expectEqualSlices(u8, "python", doc.root.tag);
}
