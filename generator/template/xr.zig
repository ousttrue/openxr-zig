// This file is generated from the Khronos OpenXR XML API registry by openxr-zig

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
pub const core = @import("core.zig");

// pub fn FlagsMixin(comptime FlagsType: type) type {
//     return struct {
//         pub const IntType = Flags64;
//         pub fn toInt(this: FlagsType) IntType {
//             return @bitCast(this);
//         }
//         pub fn fromInt(flags: IntType) FlagsType {
//             return @bitCast(flags);
//         }
//         pub fn merge(lhs: FlagsType, rhs: FlagsType) FlagsType {
//             return fromInt(toInt(lhs) | toInt(rhs));
//         }
//         pub fn intersect(lhs: FlagsType, rhs: FlagsType) FlagsType {
//             return fromInt(toInt(lhs) & toInt(rhs));
//         }
//         pub fn complement(this: FlagsType) FlagsType {
//             return fromInt(~toInt(this));
//         }
//         pub fn subtract(lhs: FlagsType, rhs: FlagsType) FlagsType {
//             return fromInt(toInt(lhs) & toInt(rhs.complement()));
//         }
//         pub fn contains(lhs: FlagsType, rhs: FlagsType) bool {
//             return toInt(intersect(lhs, rhs)) == toInt(rhs);
//         }
//     };
// }
