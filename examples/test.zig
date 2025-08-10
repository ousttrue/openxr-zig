const c = @import("c.zig");
const std = @import("std");
const xr = @import("openxr");
const xr_helper = @import("xr_helper.zig");
const xr_graphics_vk = @import("xr_graphics_vk.zig");
const SessionState = @import("SessionState.zig");
const Renderer = @import("Renderer.zig");
const Stereoscope = @import("Stereoscope.zig");
const Swapchain = @import("Swapchain.zig");

fn timeToColor(nano: i64) [4]f32 {
    const s = std.math.sin(@as(f64, @floatFromInt(nano)) / std.time.ns_per_s * std.math.pi);
    return [4]f32{ @floatCast((s + 1) / 2.0), 0, 0, 1 };
}

pub fn main() !void {
    if (c.glfwInit() == 0) {
        @panic("OOP");
    }

    var name: [128]u8 = undefined;
    std.mem.copyForwards(u8, name[0..], "openxr-zig-test" ++ [_]u8{0});

    const xrb = try xr_helper.XrBaseDispatch.load(c.xrGetInstanceProcAddr);

    const xr_instance = try xrb.createInstance(&.{
        .application_info = .{
            .application_name = name,
            .application_version = 0,
            .engine_name = name,
            .engine_version = 0,
            .api_version = xr.makeVersion(1, 0, 0),
        },
        .enabled_extension_count = 1,
        .enabled_extension_names = &.{"XR_KHR_vulkan_enable2"},
    });

    const xri = try xr_helper.XrInstanceDispatch.load(xr_instance, c.xrGetInstanceProcAddr);
    defer xri.destroyInstance(xr_instance) catch unreachable;
    {
        var instance_properties = xr.InstanceProperties.empty();
        try xri.getInstanceProperties(xr_instance, &instance_properties);
        std.log.debug("runtimeName: {s}", .{std.mem.sliceTo(&instance_properties.runtime_name, 0)});
    }

    const xr_system_id = try xri.getSystem(xr_instance, &.{ .form_factor = .head_mounted_display });
    {
        var system_properties = xr.SystemProperties.empty();
        try xri.getSystemProperties(xr_instance, xr_system_id, &system_properties);
        std.log.debug("systemName: {s}", .{std.mem.sliceTo(&system_properties.system_name, 0)});
    }

    const g = try xr_graphics_vk.init(&xri, xr_instance, xr_system_id);

    //
    // xr session
    //
    const xr_session = try xri.createSession(xr_instance, &.{
        .system_id = xr_system_id,
        .next = &g.binding,
    });
    std.log.debug("xrSession: {}", .{xr_session});

    // space
    const reference_space_create_info = xr.ReferenceSpaceCreateInfo{
        .reference_space_type = .local,
        .pose_in_reference_space = .{},
    };
    const app_space = try xri.createReferenceSpace(xr_session, &reference_space_create_info);
    std.log.debug("xrSpace:{}", .{app_space});

    const view_configuration_type = xr.ViewConfigurationType.primary_stereo;
    var stereoscope = try Stereoscope.init(
        &xri,
        xr_instance,
        xr_system_id,
        xr_session,
        view_configuration_type,
    );

    // swapchain
    const format = try xr_graphics_vk.selectSwapchainFormat(std.heap.page_allocator, &xri, xr_session);
    var swapchains = [2]Swapchain{
        try Swapchain.init(std.heap.page_allocator, &xri, xr_session, format, stereoscope.view_configurations[0]),
        try Swapchain.init(std.heap.page_allocator, &xri, xr_session, format, stereoscope.view_configurations[1]),
    };
    defer swapchains[0].deinit();
    defer swapchains[1].deinit();

    var composition_layer_projection_views = [2]xr.CompositionLayerProjectionView{
        xr.CompositionLayerProjectionView.empty(),
        xr.CompositionLayerProjectionView.empty(),
    };
    const environment_blend_mode: xr.EnvironmentBlendMode = .@"opaque";

    // renderer
    var renderer = try Renderer.init(g.instance, g.device, g.queue_family_index);
    defer renderer.deinit();

    // xr session state manager
    var state = try SessionState.init(
        std.heap.page_allocator,
        &xri,
        xr_instance,
        xr_session,
        .primary_stereo,
    );
    defer state.deinit();

    while (try state.pollEvents()) {
        if (!state.canRendering()) {
            // Throttle loop since xrWaitFrame won't be called.
            std.time.sleep(std.time.ns_per_ms * 250);
            continue;
        }

        // frame
        const frame_wait_info = xr.FrameWaitInfo.empty();
        var frame_state = xr.FrameState.empty();
        try xri.waitFrame(xr_session, &frame_wait_info, &frame_state);

        const frame_begin_info = xr.FrameBeginInfo.empty();
        const xr_result = try xri.beginFrame(xr_session, &frame_begin_info);
        std.debug.assert(xr_result == .success);

        // composition
        var frame_end_info = xr.FrameEndInfo{
            .environment_blend_mode = environment_blend_mode,
            .display_time = frame_state.predicted_display_time,
            .layer_count = 0,
            .layers = null,
        };

        var p_composition_layer_base_header: ?*const xr.CompositionLayerBaseHeader = null;

        // render CompositionLayerProjection
        var composition_layer_projection = xr.CompositionLayerProjection.empty();
        if (frame_state.should_render != 0) {
            if (try stereoscope.locate(
                app_space,
                frame_state.predicted_display_time,
            )) {
                // scene update
                const color = timeToColor(frame_state.predicted_display_time);

                // HMD tracking enabled
                for (&stereoscope.views, 0..) |*view, i| {
                    // CompositionLayerProjection Left/Right

                    // get swapchain...
                    var swapchain = swapchains[i];
                    const acquired = try swapchain.acquireSwapchain(view);
                    composition_layer_projection_views[i] = acquired.projection_view;

                    // render
                    try renderer.render(acquired.image.image, .{ .float_32 = color });

                    try swapchain.endSwapchain();
                }

                // composit
                composition_layer_projection.space = app_space;
                composition_layer_projection.view_count = 2;
                composition_layer_projection.views = &composition_layer_projection_views;
                frame_end_info.layer_count = 1;
                p_composition_layer_base_header = @ptrCast(&composition_layer_projection);
                frame_end_info.layers = @ptrCast(&p_composition_layer_base_header);
            }
        }

        try xri.endFrame(xr_session, &frame_end_info);
    }
}
