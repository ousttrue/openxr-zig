const std = @import("std");
const c_types = @import("c_types.zig");
const xml = @import("../xml/xml.zig");
const XmlElement = xml.XmlDocument.Element;
const XmlCTokenizer = @import("XmlCTokenizer.zig");

pub const Field = struct {
    name: []const u8,
    field_type: c_types.TypeInfo,
    bits: ?usize,
    is_buffer_len: bool,
    is_optional: bool,

    // MEMBER = DECLARATION (':' int)?
    pub fn parseMember(
        allocator: std.mem.Allocator,
        member: *XmlElement,
        ptrs_optional: bool,
    ) !@This() {
        var xctok = XmlCTokenizer.init(member);
        const decl = try xctok.parseDeclaration(allocator, ptrs_optional);
        var field = @This(){
            .name = decl.name orelse return error.MissingTypeIdentifier,
            .field_type = decl.decl_type,
            .bits = null,
            .is_buffer_len = false,
            .is_optional = false,
        };

        if (try xctok.peek()) |tok| {
            if (tok.kind != .colon) {
                return error.InvalidSyntax;
            }

            _ = try xctok.nextNoEof();
            const bits = try xctok.expect(.int);
            field.bits = try std.fmt.parseInt(usize, bits.text, 10);

            // Assume for now that there won't be any invalid C types like `char char* x : 4`.

            if (try xctok.peek()) |_| {
                return error.InvalidSyntax;
            }
        }

        return field;
    }

    pub fn parsePointerMeta(
        this: *@This(),
        // type_info: *c_types.TypeInfo,
        fields: []@This(),
        elem: *XmlElement,
    ) !void {
        if (elem.getAttribute("len")) |lens| {
            switch (this.field_type) {
                .pointer => {
                    // <member len="enabledApiLayerCount,null-terminated">const <type>char</type>* const*      <name>enabledApiLayerNames</name></member>
                    var it = std.mem.splitScalar(u8, lens, ',');
                    var current_type_info = &this.field_type;
                    while (current_type_info.* == .pointer) {
                        // TODO: Check altlen
                        const size = if (it.next()) |len_str| blk: {
                            const size_optional = lenToPointer(fields, len_str);
                            current_type_info.pointer.is_optional = size_optional[1];
                            break :blk size_optional[0];
                        } else .many;
                        current_type_info.pointer.size = size;
                        current_type_info = current_type_info.pointer.child;
                    }
                    if (it.next()) |_| {
                        // There are more elements in the `len` attribute than there are pointers
                        // Something probably went wrong
                        std.log.err("len: {s}", .{lens});
                        return error.InvalidRegistry;
                    }
                },
                else => {
                    // <member len="viewCount">const <type>XrCompositionLayerProjectionView</type>* <name>views</name></member>
                    // <member len="bufferSize"><type>uint8_t</type> <name>buffer</name>[<enum>XR_MAX_COLOCATION_DISCOVERY_BUFFER_SIZE_META</enum>]</member>
                },
            }
        }

        if (elem.getAttribute("optional")) |optionals| {
            var it = std.mem.splitScalar(u8, optionals, ',');
            var current_type_info = &this.field_type;
            while (current_type_info.* == .pointer) {
                if (it.next()) |current_optional| {
                    current_type_info.pointer.is_optional = std.mem.eql(u8, current_optional, "true");
                } else {
                    current_type_info.pointer.is_optional = true;
                    // There is no information for this pointer, probably incorrect.
                    // return error.InvalidRegistry;
                }

                current_type_info = current_type_info.pointer.child;
            }
        } else if (std.mem.eql(u8, elem.getCharData("name") orelse "", "next")) {
            this.field_type.pointer.is_optional = true;
        }
    }
};

stype: ?[]const u8,
extends: ?[]const []const u8,
fields: []Field,
is_union: bool,

fn lenToPointer(members: []Field, len: []const u8) std.meta.Tuple(&.{
    c_types.Pointer.Size,
    bool,
}) {
    for (members) |*member| {
        if (std.mem.eql(u8, member.name, len)) {
            member.is_buffer_len = true;
            return .{ .{ .other_field = member.name }, member.is_optional };
        }
    }
    if (std.mem.eql(u8, len, "null-terminated")) {
        return .{ .zero_terminated, false };
    } else {
        return .{ .many, false };
    }
}

fn allocMembers(allocator: std.mem.Allocator, ty: *XmlElement) !struct { []Field, ?[]const u8 } {
    var members = try allocator.alloc(Field, ty.children.len);
    var i: usize = 0;
    var maybe_stype: ?[]const u8 = null;
    {
        var it = ty.findChildrenByTag("member");
        while (it.next()) |member| {
            members[i] = try Field.parseMember(allocator, member, false);
            if (std.mem.eql(u8, members[i].name, "type")) {
                if (member.getAttribute("values")) |stype| {
                    maybe_stype = stype;
                }
            }

            if (member.getAttribute("optional")) |optionals| {
                var optional_it = std.mem.splitScalar(u8, optionals, ',');
                if (optional_it.next()) |first_optional| {
                    members[i].is_optional = std.mem.eql(u8, first_optional, "true");
                } else {
                    // Optional is empty, probably incorrect.
                    return error.InvalidRegistry;
                }
            }
            i += 1;
        }
    }
    return .{ members[0..i], maybe_stype };
}

pub fn parse(allocator: std.mem.Allocator, ty: *XmlElement, is_union: bool) !@This() {
    const members, const stype = try allocMembers(allocator, ty);

    var maybe_extends: ?[][]const u8 = null;
    if (ty.getAttribute("structextends")) |extends| {
        const n_structs = std.mem.count(u8, extends, ",") + 1;
        maybe_extends = try allocator.alloc([]const u8, n_structs);
        var struct_extends = std.mem.splitScalar(u8, extends, ',');
        var j: usize = 0;
        while (struct_extends.next()) |struct_extend| {
            maybe_extends.?[j] = struct_extend;
            j += 1;
        }
    }

    {
        var it = ty.findChildrenByTag("member");
        for (members) |*member| {
            const member_elem = it.next().?;
            member.parsePointerMeta(members, member_elem) catch |e| {
                std.log.err("{f}", .{member_elem});
                return e;
            };

            // next isn't always properly marked as optional, so just manually override it,
            if (std.mem.eql(u8, member.name, "next")) {
                member.field_type.pointer.is_optional = true;
            }
        }
    }

    return @This(){
        .stype = stype,
        .fields = members,
        .is_union = is_union,
        .extends = maybe_extends,
    };
}
