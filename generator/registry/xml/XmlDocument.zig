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
