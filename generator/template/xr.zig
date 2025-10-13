const std = @import("std");
pub const core = @import("core.zig");

pub fn getProcs(
    loader: anytype,
    create_info: *const core.InstanceCreateInfo,
    instance: *core.Instance,
    table: anytype,
) !void {
    // load xrCreateInstance and execute
    {
        const name: [*:0]const u8 = @ptrCast("xrCreateInstance\x00");
        var cmd_ptr: core.PfnVoidFunction = undefined;
        const result: core.Result = loader(core.Instance.null_handle, name, &cmd_ptr);
        if (result != .success) return error.CreateInstanceCommandLoadFailure;
        const xrCreateInstance: core.PfnCreateInstance = @ptrCast(cmd_ptr);

        const res = xrCreateInstance(create_info, instance);
        if (res != core.Result.success) {
            return error.xrCreateInstance;
        }
    }

    inline for (std.meta.fields(@typeInfo(@TypeOf(table)).pointer.child)) |field| {
        const name: [*:0]const u8 = @ptrCast(field.name ++ "\x00");
        var cmd_ptr: core.PfnVoidFunction = undefined;
        const result: core.Result = loader(instance.*, name, &cmd_ptr);
        if (result != .success) return error.CommandLoadFailure;
        @field(table, field.name) = @ptrCast(cmd_ptr);
    }
}
