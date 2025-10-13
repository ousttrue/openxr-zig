const std = @import("std");
const xr = @import("openxr").core;
const Allocator = std.mem.Allocator;

const DispatchTable = struct {
    xrDestroyInstance: xr.PfnDestroyInstance,
};

fn load(
    loader: anytype,
    create_info: *const xr.InstanceCreateInfo,
    instance: *xr.Instance,
    table: *DispatchTable,
) !void {
    // load xrCreateInstance and execute
    {
        const name: [*:0]const u8 = @ptrCast("xrCreateInstance\x00");
        var cmd_ptr: xr.PfnVoidFunction = undefined;
        const result: xr.Result = loader(xr.Instance.null_handle, name, &cmd_ptr);
        std.debug.assert(result == .success);
        const xrCreateInstance: xr.PfnCreateInstance = @ptrCast(cmd_ptr);

        const res = xrCreateInstance(create_info, instance);
        if (res != xr.Result.success) {
            return error.xrCreateInstance;
        }
    }

    // load other xrCreateInstance
    inline for (std.meta.fields(DispatchTable)) |field| {
        const name: [*:0]const u8 = @ptrCast(field.name ++ "\x00");
        var cmd_ptr: xr.PfnVoidFunction = undefined;
        const result: xr.Result = loader(instance.*, name, &cmd_ptr);
        if (result != .success) return error.CommandLoadFailure;
        @field(table, field.name) = @ptrCast(cmd_ptr);
    }
}

pub extern fn xrGetInstanceProcAddr(instance: xr.Instance, procname: [*:0]const u8, function: *xr.PfnVoidFunction) xr.Result;

pub fn main() !void {
    var create_info: xr.InstanceCreateInfo = .{
        .application_info = .{
            .application_version = 0,
            .application_name = [1]u8{0} ** xr.MAX_APPLICATION_NAME_SIZE,
            .engine_version = 0,
            .engine_name = [1]u8{0} ** xr.MAX_ENGINE_NAME_SIZE,
            .api_version = xr.makeVersion(1, 0, 0),
        },
    };
    _ = try std.fmt.bufPrintZ(&create_info.application_info.application_name, "{s}", .{"openxr-zig-app"});
    _ = try std.fmt.bufPrintZ(&create_info.application_info.engine_name, "{s}", .{"openxr-zig-engine"});

    var instance: xr.Instance = undefined;
    var dispatcher: DispatchTable = undefined;
    try load(
        xrGetInstanceProcAddr,
        &create_info,
        &instance,
        &dispatcher,
    );
    defer _ = dispatcher.xrDestroyInstance(instance);

    // const xrb = try BaseDispatch.load(c.xrGetInstanceProcAddr);
    //
    // const inst = try xrb.createInstance(&.{
    //     .application_info = .{
    //         .application_name = name,
    //         .application_version = 0,
    //         .engine_name = name,
    //         .engine_version = 0,
    //         .api_version = xr.makeVersion(1, 0, 0),
    //     },
    // });
    //
    // const xri = try InstanceDispatch.load(inst, c.xrGetInstanceProcAddr);
    // defer xri.destroyInstance(inst) catch unreachable;
    //
    // const system = try xri.getSystem(inst, &.{ .form_factor = .head_mounted_display });
    //
    // var system_properties = xr.SystemProperties.empty();
    // try xri.getSystemProperties(inst, system, &system_properties);
    //
    // std.debug.print(
    //     \\system {}:
    //     \\  vendor Id: {}
    //     \\  systemName: {s}
    //     \\  gfx
    //     \\    max swapchain image resolution: {}x{}
    //     \\    max layer count: {}
    //     \\  tracking
    //     \\    orientation tracking: {}
    //     \\    positional tracking: {}
    // , .{
    //     system,
    //     system_properties.vendor_id,
    //     system_properties.system_name,
    //     system_properties.graphics_properties.max_swapchain_image_width,
    //     system_properties.graphics_properties.max_swapchain_image_height,
    //     system_properties.graphics_properties.max_layer_count,
    //     system_properties.tracking_properties.orientation_tracking,
    //     system_properties.tracking_properties.position_tracking,
    // });
    //
    // _ = try xri.createSession(inst, &.{
    //     .system_id = system,
    // });
}
