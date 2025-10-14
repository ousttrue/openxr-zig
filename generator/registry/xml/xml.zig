const std = @import("std");
const XmlParser = @import("XmlParser.zig");
pub const XmlDocument = @import("XmlDocument.zig");
const Element = XmlDocument.Element;

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !XmlDocument {
    var parser = XmlParser.init(allocator, src);

    var doc = XmlDocument{
        .allocator = allocator,
        .xml_decl = null,
        .root = undefined,
    };

    try parser.skipComments();

    doc.xml_decl = try parser.parseElement(.xml_decl);
    _ = parser.eatWs();
    _ = parser.eatStr("<!DOCTYPE xml>");
    _ = parser.eatWs();

    // xr.xml currently has 2 processing instruction tags, they're handled manually for now
    _ = try parser.parseElement(.xml_decl);
    _ = parser.eatWs();
    _ = try parser.parseElement(.xml_decl);
    _ = parser.eatWs();

    try parser.skipComments();

    doc.root = (try parser.parseElement(.element)) orelse return error.InvalidDocument;
    _ = parser.eatWs();
    try parser.skipComments();

    if (parser.peek() != null) return error.InvalidDocument;

    return doc;
}

test "xml: Parser" {
    {
        var parser = XmlParser.init(std.testing.allocator, "I like pythons");
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
        var parser = XmlParser.init(std.testing.allocator, "");
        try std.testing.expectEqual(parser.peek(), null);
        try std.testing.expectError(error.UnexpectedEof, parser.consume());
        try std.testing.expectEqual(parser.eat('p'), false);
        try std.testing.expectError(error.UnexpectedEof, parser.expect('p'));
    }
}

test "xml: parseElement" {
    const a = std.testing.allocator;
    {
        var parser = XmlParser.init(std.testing.allocator, "<= a='b'/>");
        const elem = try parser.parseElement(.element);
        try std.testing.expectEqual(@as(?*Element, null), elem);
        try std.testing.expectEqual(@as(?u8, '<'), parser.peek());
    }

    {
        var parser = XmlParser.init(std.testing.allocator, "<python size='15' color = \"green\"/>");
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
        var parser = XmlParser.init(std.testing.allocator, "<python>test</python>");
        const elem = (try parser.parseElement(.element)).?;
        defer elem.destroy(a);
        try std.testing.expectEqualSlices(u8, elem.tag, "python");
        try std.testing.expectEqualSlices(u8, elem.children[0].char_data, "test");
    }

    {
        var parser = XmlParser.init(a, "<a>b<c/>d<e/>f<!--g--></a>");
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
        var parser = XmlParser.init(a, "<?xmla version='aa'?>");
        const decl = (try parser.parseElement(.xml_decl)).?;
        defer decl.destroy(a);
        try std.testing.expectEqualSlices(u8, decl.tag, "xmla");
        try std.testing.expectEqualSlices(u8, "aa", decl.getAttribute("version").?);
    }

    {
        var parser = XmlParser.init(a, "<?xml version='aa'?>");
        const decl = (try parser.parseElement(.xml_decl)).?;
        defer decl.destroy(a);
        try std.testing.expectEqualSlices(u8, "aa", decl.getAttribute("version").?);
        try std.testing.expectEqual(@as(?[]const u8, null), decl.getAttribute("encoding"));
        try std.testing.expectEqual(@as(?[]const u8, null), decl.getAttribute("standalone"));
    }

    {
        var parser = XmlParser.init(a, "<?xml version=\"ccc\" encoding = 'bbb' standalone   \t =   'yes'?>");
        const decl = (try parser.parseElement(.xml_decl)).?;
        defer decl.destroy(a);
        try std.testing.expectEqualSlices(u8, "ccc", decl.getAttribute("version").?);
        try std.testing.expectEqualSlices(u8, "bbb", decl.getAttribute("encoding").?);
        try std.testing.expectEqualSlices(u8, "yes", decl.getAttribute("standalone").?);
    }
}

test "xml: top level comments" {
    var doc = try parse(
        std.testing.allocator,
        "<?xml version='aa'?><!--comment--><python color='green'/><!--another comment-->",
    );
    defer doc.deinit();
    try std.testing.expectEqualSlices(u8, "python", doc.root.tag);
}
