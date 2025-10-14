const std = @import("std");
const xml = @import("xml/xml.zig");
const XmlDocument = xml.XmlDocument;
const Element = XmlDocument.Element;
const Registry = @import("Registry.zig");
const CTokenizer = @import("CTokenizer.zig");
const c_types = @import("c_types.zig");

pub const ParseError = error{
    OutOfMemory,
    InvalidSyntax,
    InvalidTag,
    InvalidXml,
    Overflow,
    UnexpectedEof,
    UnexpectedCharacter,
    UnexpectedToken,
    MissingTypeIdentifier,
};

it: Element.ChildIterator,
ctok: ?CTokenizer = null,
current: ?CTokenizer.Token = null,

pub fn init(elem: *Element) @This() {
    return .{
        .it = elem.iterator(),
    };
}

fn elemToToken(elem: *Element) !?CTokenizer.Token {
    if (elem.children.len != 1 or elem.children[0] != .char_data) {
        return error.InvalidXml;
    }

    const text = elem.children[0].char_data;
    if (std.mem.eql(u8, elem.tag, "type")) {
        return CTokenizer.Token{ .kind = .type_name, .text = text };
    } else if (std.mem.eql(u8, elem.tag, "enum")) {
        return CTokenizer.Token{ .kind = .enum_name, .text = text };
    } else if (std.mem.eql(u8, elem.tag, "name")) {
        return CTokenizer.Token{ .kind = .name, .text = text };
    } else if (std.mem.eql(u8, elem.tag, "comment")) {
        return null;
    } else {
        return error.InvalidTag;
    }
}

fn next(self: *@This()) !?CTokenizer.Token {
    if (self.current) |current| {
        const token = current;
        self.current = null;
        return token;
    }

    var in_comment: bool = false;

    while (true) {
        if (self.ctok) |*ctok| {
            if (try ctok.next()) |tok| {
                return tok;
            }
            in_comment = ctok.in_comment;
        }

        self.ctok = null;

        if (self.it.next()) |child| {
            switch (child.*) {
                .char_data => |cdata| self.ctok = CTokenizer{ .source = cdata, .in_comment = in_comment },
                .comment => {}, // xml comment
                .element => |elem| if (!in_comment) if (try elemToToken(elem)) |tok| return tok,
            }
        } else {
            return null;
        }
    }
}

fn nextNoEof(self: *@This()) !CTokenizer.Token {
    return (try self.next()) orelse return error.UnexpectedEof;
}

fn peek(self: *@This()) !?CTokenizer.Token {
    if (self.current) |current| {
        return current;
    }

    self.current = try self.next();
    return self.current;
}

fn peekNoEof(self: *@This()) !CTokenizer.Token {
    return (try self.peek()) orelse return error.UnexpectedEof;
}

fn expect(self: *@This(), kind: CTokenizer.Token.Kind) !CTokenizer.Token {
    const tok = (try self.next()) orelse return error.UnexpectedEof;
    if (tok.kind != kind) {
        return error.UnexpectedToken;
    }

    return tok;
}

// TYPEDEF = kw_typedef DECLARATION ';'
pub fn parseTypedef(
    self: *@This(),
    allocator: std.mem.Allocator,
    ptrs_optional: bool,
) !Registry.Declaration {
    var useNext = true;
    while (useNext) {
        useNext = false;
        const first_tok = (try self.next()) orelse return error.UnexpectedEof;

        _ = switch (first_tok.kind) {
            .kw_typedef => {
                const decl = try self.parseDeclaration(allocator, ptrs_optional);
                _ = try self.expect(.semicolon);
                if (try self.peek()) |t| {
                    std.log.err("peek: {f}", .{t});
                    // return error.InvalidSyntax;
                    useNext = true;
                    continue;
                }

                return Registry.Declaration{
                    .name = decl.name orelse return error.MissingTypeIdentifier,
                    .decl_type = .{ .typedef = decl.decl_type },
                };
            },
            .type_name => {
                if (std.mem.eql(u8, first_tok.text, "XR_DEFINE_ATOM") or
                    std.mem.eql(u8, first_tok.text, "XR_DEFINE_OPAQUE_64"))
                {
                    _ = try self.expect(.lparen);
                    const name = try self.expect(.name);
                    _ = try self.expect(.rparen);

                    return Registry.Declaration{
                        .name = name.text,
                        .decl_type = .{ .typedef = .{ .name = "uint64_t" } },
                    };
                }

                return error.InvalidSyntax;
            },
            else => {
                std.debug.print("unexpected first token in typedef: {}\n", .{first_tok.kind});
                return error.InvalidSyntax;
            },
        };
    }
    unreachable;
}

pub fn parseParamOrProto(self: *@This(), allocator: std.mem.Allocator, ptrs_optional: bool) !Registry.Declaration {
    var decl = try self.parseDeclaration(allocator, ptrs_optional);
    if (try self.peek()) |_| {
        return error.InvalidSyntax;
    }

    // Decay pointers
    switch (decl.decl_type) {
        .array => {
            const child = try allocator.create(c_types.TypeInfo);
            child.* = decl.decl_type;

            decl.decl_type = .{
                .pointer = .{
                    .is_const = decl.is_const,
                    .is_optional = false,
                    .size = .one,
                    .child = child,
                },
            };
        },
        else => {},
    }

    return Registry.Declaration{
        .name = decl.name orelse return error.MissingTypeIdentifier,
        .decl_type = .{ .typedef = decl.decl_type },
    };
}

// MEMBER = DECLARATION (':' int)?
pub fn parseMember(self: *@This(), allocator: std.mem.Allocator, ptrs_optional: bool) !Registry.Container.Field {
    const decl = try self.parseDeclaration(allocator, ptrs_optional);
    var field = Registry.Container.Field{
        .name = decl.name orelse return error.MissingTypeIdentifier,
        .field_type = decl.decl_type,
        .bits = null,
        .is_buffer_len = false,
        .is_optional = false,
    };

    if (try self.peek()) |tok| {
        if (tok.kind != .colon) {
            return error.InvalidSyntax;
        }

        _ = try self.nextNoEof();
        const bits = try self.expect(.int);
        field.bits = try std.fmt.parseInt(usize, bits.text, 10);

        // Assume for now that there won't be any invalid C types like `char char* x : 4`.

        if (try self.peek()) |_| {
            return error.InvalidSyntax;
        }
    }

    return field;
}

pub const CDeclaration = struct {
    name: ?[]const u8, // Parameter names may be optional, especially in case of func(void)
    decl_type: c_types.TypeInfo,
    is_const: bool,
};

// DECLARATION = kw_const? type_name DECLARATOR
// DECLARATOR = POINTERS (id | name)? ('[' ARRAY_DECLARATOR ']')*
//     | POINTERS '(' FNPTRSUFFIX
fn parseDeclaration(
    self: *@This(),
    allocator: std.mem.Allocator,
    ptrs_optional: bool,
) ParseError!CDeclaration {
    // Parse declaration constness
    var tok = try self.nextNoEof();
    const inner_is_const = tok.kind == .kw_const;
    if (inner_is_const) {
        tok = try self.nextNoEof();
    }

    if (tok.kind == .kw_struct) {
        tok = try self.nextNoEof();
    }
    // Parse type name
    if (tok.kind != .type_name and tok.kind != .id) return error.InvalidSyntax;
    const type_name = tok.text;

    var type_info = c_types.TypeInfo{ .name = type_name };

    // Parse pointers
    type_info = try self.parsePointers(allocator, inner_is_const, type_info, ptrs_optional);

    // Parse name / fn ptr

    if (try self.parseFnPtrSuffix(allocator, type_info, ptrs_optional)) |decl| {
        return CDeclaration{
            .name = decl.name,
            .decl_type = decl.decl_type,
            .is_const = inner_is_const,
        };
    }

    const name = blk: {
        const name_tok = (try self.peek()) orelse break :blk null;
        if (name_tok.kind == .id or name_tok.kind == .name) {
            _ = try self.nextNoEof();
            break :blk name_tok.text;
        } else {
            break :blk null;
        }
    };

    var inner_type = &type_info;
    while (try parseArrayDeclarator(self)) |array_size| {
        // Move the current inner type to a new node on the heap
        const child = try allocator.create(c_types.TypeInfo);
        child.* = inner_type.*;

        // Re-assign the previous inner type for the array type info node
        inner_type.* = .{
            .array = .{
                .size = array_size,
                .child = child,
            },
        };

        // update the inner_type pointer so it points to the proper
        // inner type again
        inner_type = child;
    }

    return CDeclaration{
        .name = name,
        .decl_type = type_info,
        .is_const = inner_is_const,
    };
}

// FNPTRSUFFIX = kw_xrapi_ptr '*' name' ')' '(' ('void' | (DECLARATION (',' DECLARATION)*)?) ')'
fn parseFnPtrSuffix(
    self: *@This(),
    allocator: std.mem.Allocator,
    return_type: c_types.TypeInfo,
    ptrs_optional: bool,
) !?CDeclaration {
    const lparen = try self.peek();
    if (lparen == null or lparen.?.kind != .lparen) {
        return null;
    }
    _ = try self.nextNoEof();

    if (try self.peek()) |kw_xrapi_ptr| {
        if (kw_xrapi_ptr.kind == .kw_xrapi_ptr) {
            _ = try self.expect(.kw_xrapi_ptr);
        } else {
            // skip
        }
    } else {
        return null;
    }
    _ = try self.expect(.star);
    const name = try self.expect(.name);
    _ = try self.expect(.rparen);
    _ = try self.expect(.lparen);

    const return_type_heap = try allocator.create(c_types.TypeInfo);
    return_type_heap.* = return_type;

    var command_ptr = CDeclaration{
        .name = name.text,
        .decl_type = .{
            .command_ptr = .{
                .name = name.text,
                .params = &[_]c_types.Command.Param{},
                .return_type = return_type_heap,
                .success_codes = &[_][]const u8{},
                .error_codes = &[_][]const u8{},
            },
        },
        .is_const = false,
    };

    const first_param = try self.parseDeclaration(allocator, ptrs_optional);
    if (first_param.name == null) {
        if (first_param.decl_type != .name or !std.mem.eql(u8, first_param.decl_type.name, "void")) {
            return error.InvalidSyntax;
        }

        _ = try self.expect(.rparen);
        return command_ptr;
    }

    // There is no good way to estimate the number of parameters beforehand.
    // Fortunately, there are usually a relatively low number of parameters to a function pointer,
    // so an ArrayList backed by an arena allocator is good enough.
    var params = std.array_list.Managed(c_types.Command.Param).init(allocator);
    try params.append(.{
        .name = first_param.name.?,
        .param_type = first_param.decl_type,
        .is_buffer_len = false,
    });

    while (true) {
        switch ((try self.peekNoEof()).kind) {
            .rparen => break,
            .comma => _ = try self.nextNoEof(),
            else => return error.InvalidSyntax,
        }

        const decl = try self.parseDeclaration(allocator, ptrs_optional);
        try params.append(.{
            .name = decl.name orelse return error.MissingTypeIdentifier,
            .param_type = decl.decl_type,
            .is_buffer_len = false,
        });
    }

    _ = try self.nextNoEof();
    command_ptr.decl_type.command_ptr.params = try params.toOwnedSlice();
    return command_ptr;
}

// POINTERS = (kw_const? '*')*
fn parsePointers(
    self: *@This(),
    allocator: std.mem.Allocator,
    inner_const: bool,
    inner: c_types.TypeInfo,
    ptrs_optional: bool,
) !c_types.TypeInfo {
    var type_info = inner;
    var first_const = inner_const;

    while (true) {
        var tok = (try self.peek()) orelse return type_info;
        var is_const = first_const;
        first_const = false;

        if (tok.kind == .kw_const) {
            is_const = true;
            _ = try self.nextNoEof();
            tok = (try self.peek()) orelse return type_info;
        }

        if (tok.kind != .star) {
            // if `is_const` is true at this point, there was a trailing const,
            // and the declaration itself is const.
            return type_info;
        }

        _ = try self.nextNoEof();

        const child = try allocator.create(c_types.TypeInfo);
        child.* = type_info;

        type_info = .{
            .pointer = .{
                .is_const = is_const or first_const,
                .is_optional = ptrs_optional, // set elsewhere
                .size = .one, // set elsewhere
                .child = child,
            },
        };
    }
}

// ARRAY_DECLARATOR = '[' (int | enum_name) ']'
fn parseArrayDeclarator(self: *@This()) !?c_types.Array.Size {
    const lbracket = try self.peek();
    if (lbracket == null or lbracket.?.kind != .lbracket) {
        return null;
    }

    _ = try self.nextNoEof();

    const size_tok = try self.nextNoEof();
    const size: c_types.Array.Size = switch (size_tok.kind) {
        .int => .{
            .int = std.fmt.parseInt(usize, size_tok.text, 10) catch |err| switch (err) {
                error.Overflow => return error.Overflow,
                error.InvalidCharacter => unreachable,
            },
        },
        .enum_name => .{ .alias = size_tok.text },
        .id => .{ .alias = size_tok.text },
        else => return error.InvalidSyntax,
    };

    _ = try self.expect(.rbracket);
    return size;
}

pub fn parseVersion(self: *@This()) ![3][]const u8 {
    _ = try self.expect(.hash);
    const define = try self.expect(.id);
    if (!std.mem.eql(u8, define.text, "define")) {
        return error.InvalidVersion;
    }

    _ = try self.expect(.name);
    const xr_make_version = try self.expect(.type_name);
    if (!std.mem.eql(u8, xr_make_version.text, "XR_MAKE_VERSION")) {
        return error.NotVersion;
    }

    _ = try self.expect(.lparen);
    var version: [3][]const u8 = undefined;
    for (&version, 0..) |*part, i| {
        if (i != 0) {
            _ = try self.expect(.comma);
        }

        const tok = try self.nextNoEof();
        switch (tok.kind) {
            .id, .int => part.* = tok.text,
            else => return error.UnexpectedToken,
        }
    }
    _ = try self.expect(.rparen);
    return version;
}

fn testTokenizer(tokenizer: anytype, expected_tokens: []const CTokenizer.Token) !void {
    for (expected_tokens) |expected| {
        const tok = (tokenizer.next() catch unreachable).?;
        try std.testing.expectEqual(expected.kind, tok.kind);
        try std.testing.expectEqualSlices(u8, expected.text, tok.text);
    }

    if (tokenizer.next() catch unreachable) |_| unreachable;
}

test "CTokenizer" {
    var ctok = CTokenizer{ .source = "typedef ([const)]** XRAPI_PTR 123,;aaaa" };

    try testTokenizer(&ctok, &[_]CTokenizer.Token{
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

test "XmlCTokenizer" {
    var document = try xml.parse(std.testing.allocator,
        \\<root>// comment <name>commented name</name> <type>commented type</type> trailing
        \\    typedef void (XRAPI_PTR *<name>PFN_xrVoidFunction</name>)(void);
        \\</root>
    );
    defer document.deinit();

    var xctok = @This().init(document.root);

    try testTokenizer(&xctok, &[_]CTokenizer.Token{
        .{ .kind = .kw_typedef, .text = "typedef" },
        .{ .kind = .id, .text = "void" },
        .{ .kind = .lparen, .text = "(" },
        .{ .kind = .kw_xrapi_ptr, .text = "XRAPI_PTR" },
        .{ .kind = .star, .text = "*" },
        .{ .kind = .name, .text = "PFN_xrVoidFunction" },
        .{ .kind = .rparen, .text = ")" },
        .{ .kind = .lparen, .text = "(" },
        .{ .kind = .id, .text = "void" },
        .{ .kind = .rparen, .text = ")" },
        .{ .kind = .semicolon, .text = ";" },
    });
}

test "parseTypedef_1_1_50" {
    const xml_src =
        \\<type category="funcpointer">typedef PFN_xrVoidFunction (*<name>PFN_xrEglGetProcAddressMNDX</name>)(const <type>char</type> *name);</type>
    ;

    var document = try xml.parse(std.testing.allocator, xml_src);
    defer document.deinit();
}

test "parseTypedef" {
    var document = try xml.parse(std.testing.allocator,
        \\<root> // comment <name>commented name</name> trailing
        \\    typedef const struct <type>Python</type>* pythons[4];
        \\ // more comments
        \\</root>
        \\
    );
    defer document.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var xctok = @This().init(document.root);
    const decl = try xctok.parseTypedef(arena.allocator(), false);

    try std.testing.expectEqualSlices(u8, "pythons", decl.name);
    const array = decl.decl_type.typedef.array;
    try std.testing.expectEqual(c_types.Array.Size{ .int = 4 }, array.size);
    const ptr = array.child.pointer;
    try std.testing.expectEqual(true, ptr.is_const);
    try std.testing.expectEqualSlices(u8, "Python", ptr.child.name);
}
