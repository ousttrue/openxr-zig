const std = @import("std");
const xml = @import("../xml/xml.zig");

pub const Token = struct {
    kind: Kind,
    text: []const u8,

    pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s}({s})", .{ @tagName(this.kind), this.text });
    }

    pub const Kind = enum {
        id, // Any id thats not a keyword
        name, // OpenXR <name>...</name>
        type_name, // OpenXR <type>...</type>
        enum_name, // OpenXR <enum>...</enum>
        int,
        star,
        comma,
        semicolon,
        colon,
        minus,
        tilde,
        dot,
        hash,
        lparen,
        rparen,
        lbracket,
        rbracket,
        kw_typedef,
        kw_const,
        kw_xrapi_ptr,
        kw_struct,
    };
};

source: []const u8,
offset: usize = 0,
in_comment: bool = false,

fn peek(self: @This()) ?u8 {
    return if (self.offset < self.source.len) self.source[self.offset] else null;
}

fn consumeNoEof(self: *@This()) u8 {
    const c = self.peek().?;
    self.offset += 1;
    return c;
}

fn consume(self: *@This()) !u8 {
    return if (self.offset < self.source.len)
        return self.consumeNoEof()
    else
        return null;
}

fn keyword(self: *@This()) Token {
    const start = self.offset;
    _ = self.consumeNoEof();

    while (true) {
        const c = self.peek() orelse break;
        switch (c) {
            'A'...'Z', 'a'...'z', '_', '0'...'9' => _ = self.consumeNoEof(),
            else => break,
        }
    }

    const token_text = self.source[start..self.offset];

    const kind = if (std.mem.eql(u8, token_text, "typedef"))
        Token.Kind.kw_typedef
    else if (std.mem.eql(u8, token_text, "const"))
        Token.Kind.kw_const
    else if (std.mem.eql(u8, token_text, "XRAPI_PTR"))
        Token.Kind.kw_xrapi_ptr
    else if (std.mem.eql(u8, token_text, "struct"))
        Token.Kind.kw_struct
    else
        Token.Kind.id;

    return .{ .kind = kind, .text = token_text };
}

fn int(self: *@This()) Token {
    const start = self.offset;
    _ = self.consumeNoEof();

    while (true) {
        const c = self.peek() orelse break;
        switch (c) {
            '0'...'9' => _ = self.consumeNoEof(),
            else => break,
        }
    }

    return .{
        .kind = .int,
        .text = self.source[start..self.offset],
    };
}

fn skipws(self: *@This()) void {
    while (true) {
        switch (self.peek() orelse break) {
            ' ', '\t', '\n', '\r' => _ = self.consumeNoEof(),
            else => break,
        }
    }
}

pub fn next(self: *@This()) !?Token {
    self.skipws();
    if (std.mem.startsWith(u8, self.source[self.offset..], "//") or self.in_comment) {
        const end = std.mem.indexOfScalarPos(u8, self.source, self.offset, '\n') orelse {
            self.offset = self.source.len;
            self.in_comment = true;
            return null;
        };
        self.in_comment = false;
        self.offset = end + 1;
    }
    self.skipws();

    const c = self.peek() orelse return null;
    var kind: Token.Kind = undefined;
    switch (c) {
        'A'...'Z', 'a'...'z', '_' => return self.keyword(),
        '0'...'9' => return self.int(),
        '*' => kind = .star,
        ',' => kind = .comma,
        ';' => kind = .semicolon,
        ':' => kind = .colon,
        '-' => kind = .minus,
        '~' => kind = .tilde,
        '.' => kind = .dot,
        '#' => kind = .hash,
        '[' => kind = .lbracket,
        ']' => kind = .rbracket,
        '(' => kind = .lparen,
        ')' => kind = .rparen,
        else => return error.UnexpectedCharacter,
    }

    const start = self.offset;
    _ = self.consumeNoEof();
    return Token{ .kind = kind, .text = self.source[start..self.offset] };
}

fn testTokenizer(tokenizer: *@This(), expected_tokens: []const Token) !void {
    for (expected_tokens, 0..) |expected, i| {
        if (try tokenizer.next()) |tok| {
            std.testing.expectEqual(expected.kind, tok.kind) catch |e| {
                std.log.err("[{}] {f} != {f}", .{ i, expected, tok });
                return e;
            };
            std.testing.expectEqualSlices(u8, expected.text, tok.text) catch |e| {
                std.log.err("[{}] {f} != {f}", .{ i, expected, tok });
                return e;
            };
        } else {
            std.log.err("[{}] {f} != null", .{ i, expected });
            return error.token_short;
        }
    }

    if (tokenizer.next() catch unreachable) |tok| {
        std.log.err("[{}] null != {f}", .{ expected_tokens.len, tok });
        return error.token_remaining;
    }
}

test "CTokenizer" {
    var ctok = @This(){ .source = "typedef ([const)]** XRAPI_PTR 123,;aaaa" };

    try testTokenizer(&ctok, &[_]@This().Token{
        .{ .kind = .kw_typedef, .text = "typedef" },
        .{ .kind = .lparen, .text = "(" },
        .{ .kind = .lbracket, .text = "[" },
        .{ .kind = .kw_const, .text = "const" },
        .{ .kind = .rparen, .text = ")" },
        .{ .kind = .rbracket, .text = "]" },
        .{ .kind = .star, .text = "*" },
        .{ .kind = .star, .text = "*" },
        .{ .kind = .kw_xrapi_ptr, .text = "XRAPI_PTR" },
        .{ .kind = .int, .text = "123" },
        .{ .kind = .comma, .text = "," },
        .{ .kind = .semicolon, .text = ";" },
        .{ .kind = .id, .text = "aaaa" },
    });
}
