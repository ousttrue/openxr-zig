const std = @import("std");
const xml = @import("../xml/xml.zig");
const XmlElement = xml.XmlDocument.Element;
const XmlCTokenizer = @import("XmlCTokenizer.zig");
pub const Enum = @import("Enum.zig");
pub const Container = @import("Container.zig");
pub const Declaration = @import("Declaration.zig");
pub const ApiConstant = @import("ApiConstant.zig");

pub const Command = struct {
    pub const Param = struct {
        name: []const u8,
        param_type: TypeInfo,
        is_buffer_len: bool,
    };

    name: []const u8,
    params: []Param,
    return_type: *TypeInfo,
    success_codes: []const []const u8,
    error_codes: []const []const u8,

    fn lenToPointer(params: []Param, len: []const u8) std.meta.Tuple(&.{ Pointer.PointerSize, bool }) {
        for (params) |*param| {
            if (std.mem.eql(u8, param.name, len)) {
                param.is_buffer_len = true;
                return .{ .{ .other_field = param.name }, false };
            }
        }
        if (std.mem.eql(u8, len, "null-terminated")) {
            return .{ .zero_terminated, false };
        } else {
            return .{ .many, false };
        }
    }

    fn parsePointerMeta(fields: []Param, type_info: *TypeInfo, elem: *XmlElement) !void {
        if (elem.getAttribute("len")) |lens| {
            var it = std.mem.splitScalar(u8, lens, ',');
            var current_type_info = type_info;
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
        }

        if (elem.getAttribute("optional")) |optionals| {
            var it = std.mem.splitScalar(u8, optionals, ',');
            var current_type_info = type_info;
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
            type_info.pointer.is_optional = true;
        }
    }

    pub fn parse(allocator: std.mem.Allocator, elem: *XmlElement) !@This() {
        const proto = elem.findChildByTag("proto") orelse return error.InvalidRegistry;
        var proto_xctok = XmlCTokenizer.init(proto);
        const command_decl = try proto_xctok.parseParamOrProto(allocator, false);

        var params = try allocator.alloc(@This().Param, elem.children.len);

        var i: usize = 0;
        var it = elem.findChildrenByTag("param");
        while (it.next()) |param| {
            var xctok = XmlCTokenizer.init(param);
            const decl = try xctok.parseParamOrProto(allocator, false);
            params[i] = .{
                .name = decl.name,
                .param_type = decl.decl_type.typedef,
                .is_buffer_len = false,
            };
            i += 1;
        }

        const return_type = try allocator.create(TypeInfo);
        return_type.* = command_decl.decl_type.typedef;

        var success_codes: [][]const u8 = if (elem.getAttribute("successcodes")) |codes|
            try splitCommaAlloc(allocator, codes)
        else
            &[_][]const u8{};

        var error_codes: [][]const u8 = if (elem.getAttribute("errorcodes")) |codes|
            try splitCommaAlloc(allocator, codes)
        else
            &[_][]const u8{};

        for (success_codes, 0..) |code, session_i| {
            if (std.mem.eql(u8, code, "XR_SESSION_LOSS_PENDING")) {
                var move_i = session_i + 1;
                while (move_i < success_codes.len) : (move_i += 1) {
                    success_codes[move_i - 1] = success_codes[move_i];
                }
                success_codes = success_codes[0..success_codes.len];
                success_codes.len = success_codes.len - 1;

                const old_error_codes = error_codes;
                error_codes = try allocator.alloc([]const u8, error_codes.len + 1);
                std.mem.copyForwards([]const u8, error_codes, old_error_codes);
                error_codes[error_codes.len - 1] = code;
                allocator.free(old_error_codes);
                break;
            }
        }

        params = params[0..i];

        it = elem.findChildrenByTag("param");
        for (params) |*param| {
            const param_elem = it.next().?;
            try Command.parsePointerMeta(params, &param.param_type, param_elem);
        }

        return .{
            .name = command_decl.name,
            .params = params,
            .return_type = return_type,
            .success_codes = success_codes,
            .error_codes = error_codes,
        };
    }

    fn splitCommaAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
        var n_codes: usize = 1;
        for (text) |c| {
            if (c == ',') n_codes += 1;
        }

        const codes = try allocator.alloc([]const u8, n_codes);
        var it = std.mem.splitScalar(u8, text, ',');
        for (codes) |*code| {
            code.* = it.next().?;
        }

        return codes;
    }
};

pub const Pointer = struct {
    pub const PointerSize = union(enum) {
        one,
        many, // The length is given by some complex expression, possibly involving another field
        other_field: []const u8, // The length is given by some other field or parameter
        zero_terminated,
    };

    is_const: bool,
    is_optional: bool,
    size: PointerSize,
    child: *TypeInfo,
};

pub const Array = struct {
    pub const Size = union(enum) {
        int: usize,
        alias: []const u8, // Field size is given by an api constant
    };

    size: Size,
    child: *TypeInfo,
};

pub const TypeInfo = union(enum) {
    name: []const u8,
    command_ptr: Command,
    pointer: Pointer,
    array: Array,
};
