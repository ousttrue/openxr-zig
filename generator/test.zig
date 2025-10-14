const std = @import("std");

test {
    std.testing.refAllDecls(@import("registry/Registry.zig"));
    // std.testing.refAllDecls(@import("registry/XmlCTokenizer.zig"));
    // std.testing.refAllDecls(@import("registry/xml.zig"));
}
