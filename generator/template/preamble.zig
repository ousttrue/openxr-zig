const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

pub const openxr_call_conv: std.builtin.CallingConvention = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86)
    .Stdcall
else if (builtin.abi == .android and (builtin.cpu.arch.isARM() or builtin.cpu.arch.isThumb()) and builtin.Target.arm.featureSetHas(builtin.cpu.features, .has_v7) and builtin.cpu.arch.ptrBitWidth() == 32)
    // On Android 32-bit ARM targets, OpenXR functions use the "hardfloat"
    // calling convention, i.e. float parameters are passed in registers. This
    // is true even if the rest of the application passes floats on the stack,
    // as it does by default when compiling for the armeabi-v7a NDK ABI.
    .AAPCSVFP
else
    .c;

pub fn makeVersion(major: u16, minor: u16, patch: u32) u64 {
    return (@as(u64, major) << 48) | (@as(u64, minor) << 32) | patch;
}
pub fn versionMajor(version: u64) u16 {
    return @truncate(version >> 48);
}
pub fn versionMinor(version: u16) u16 {
    return @truncate(version >> 32);
}
pub fn versionPatch(version: u64) u32 {
    return @truncate(version);
}
