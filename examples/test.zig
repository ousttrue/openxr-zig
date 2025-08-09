const c = @import("c.zig");
const std = @import("std");
const xr = @import("openxr");
const vk = @import("vulkan");
const xr_helper = @import("xr_helper.zig");
const SessionState = @import("SessionState.zig");
const Renderer = @import("Renderer.zig");

fn selectQueueFamily(
    allocator: std.mem.Allocator,
    vki: *const vk.InstanceWrapper,
    vk_physical_device: vk.PhysicalDevice,
) !?u32 {
    var queue_family_count: u32 = 0;
    vki.getPhysicalDeviceQueueFamilyProperties(vk_physical_device, &queue_family_count, null);
    std.log.debug("queue_family_count: {}", .{queue_family_count});
    const queue_family_props = try allocator.alloc(vk.QueueFamilyProperties, queue_family_count);
    defer allocator.free(queue_family_props);
    vki.getPhysicalDeviceQueueFamilyProperties(vk_physical_device, &queue_family_count, @ptrCast(queue_family_props));
    var queue_family_index: ?u32 = null;
    for (queue_family_props, 0..) |prop, i| {
        std.log.debug("  [{}] graphics_bit={}", .{ i, prop.queue_flags.graphics_bit });
        if (prop.queue_flags.graphics_bit) {
            queue_family_index = @intCast(i);
        } else {}
    }
    return queue_family_index;
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

    var xr_graphics_requirement = xr.GraphicsRequirementsVulkan2KHR.empty();
    try xri.getVulkanGraphicsRequirements2KHR(xr_instance, xr_system_id, &xr_graphics_requirement);

    const vk_app_info = vk.ApplicationInfo{
        .p_application_name = "hello_xr",
        .application_version = 1,
        .p_engine_name = "hello_xr",
        .engine_version = 1,
        .api_version = @bitCast(vk.API_VERSION_1_0),
    };

    const vk_instance_create_info = vk.InstanceCreateInfo{
        .p_application_info = &vk_app_info,
        // .enabledLayerCount = static_cast<uint32_t>(instance.layers.size()),
        // .ppEnabledLayerNames = instance.layers.data(),
        // .enabledExtensionCount = static_cast<uint32_t>(instance.extensions.size()),
        // .ppEnabledExtensionNames = instance.extensions.data(),
    };

    //
    // vulkan
    //
    const xr_vulkan_instance_create_info = xr.VulkanInstanceCreateInfoKHR{
        .system_id = xr_system_id,
        .pfn_get_instance_proc_addr = &c.glfwGetInstanceProcAddress,
        .vulkan_create_info = &vk_instance_create_info,
    };

    // VkInstance
    var vk_instance: vk.Instance = undefined;
    var vk_result: vk.Result = undefined;
    try xri.createVulkanInstanceKHR(xr_instance, &xr_vulkan_instance_create_info, &vk_instance, &vk_result);
    std.debug.assert(vk_result == vk.Result.success);
    const vki = vk.InstanceWrapper.load(vk_instance, c.glfwGetInstanceProcAddress);

    // VkPhysicalDevice
    const xr_vulkan_graphics_device_get_info = xr.VulkanGraphicsDeviceGetInfoKHR{
        .system_id = xr_system_id,
        .vulkan_instance = vk_instance,
    };
    var vk_physical_device: vk.PhysicalDevice = undefined;
    try xri.getVulkanGraphicsDevice2KHR(xr_instance, &xr_vulkan_graphics_device_get_info, &vk_physical_device);
    const physical_device_props = vki.getPhysicalDeviceProperties(vk_physical_device);
    std.log.debug("vulkan: physicalDeviceName: {s}", .{physical_device_props.device_name});

    // VkDevice
    const queue_family_index = try selectQueueFamily(std.heap.page_allocator, &vki, vk_physical_device) orelse {
        @panic("no queue_family_index");
    };
    const queue_priorities = [1]f32{
        0.0,
    };
    const vk_device_queue_create_info = [1]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = queue_family_index,
            .queue_count = queue_priorities.len,
            .p_queue_priorities = &queue_priorities,
        },
    };
    //   VkPhysicalDeviceFeatures features{
    //   // features.samplerAnisotropy = VK_TRUE;
    // #ifndef ANDROID
    //       // quest3 not work
    //       .shaderStorageImageMultisample = VK_TRUE,
    // #endif
    //   };
    const vk_device_create_info = vk.DeviceCreateInfo{
        .queue_create_info_count = vk_device_queue_create_info.len,
        .p_queue_create_infos = &vk_device_queue_create_info,
        // .enabledLayerCount = static_cast<uint32_t>(instance.layers.size()),
        // .ppEnabledLayerNames = instance.layers.data(),
        // .enabledExtensionCount = static_cast<uint32_t>(device.extensions.size()),
        // .ppEnabledExtensionNames = device.extensions.data(),
        // .pEnabledFeatures = &features,
    };

    const xr_vulkan_device_create_info = xr.VulkanDeviceCreateInfoKHR{
        .system_id = xr_system_id,
        .pfn_get_instance_proc_addr = c.glfwGetInstanceProcAddress,
        .vulkan_physical_device = vk_physical_device,
        .vulkan_create_info = &vk_device_create_info,
    };

    var vk_device: vk.Device = undefined;
    try xri.createVulkanDeviceKHR(xr_instance, &xr_vulkan_device_create_info, &vk_device, &vk_result);
    std.debug.assert(vk_result == vk.Result.success);

    //
    // xr session
    //
    const xr_graphics_binding = xr.GraphicsBindingVulkan2KHR{
        .instance = vk_instance,
        .physical_device = vk_physical_device,
        .device = vk_device,
        .queue_family_index = queue_family_index,
        .queue_index = 0,
    };

    const xr_session = try xri.createSession(xr_instance, &.{
        .system_id = xr_system_id,
        .next = &xr_graphics_binding,
    });
    std.log.debug("xrSession: {}", .{xr_session});

    //
    // renderer
    //
    var renderer = try Renderer.init();
    defer renderer.deinit();

    //
    // xr session state manager
    //
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

        // render & composition
        const layers = renderer.renderAndCompositLayers(frame_state);
        const frame_end_info = xr.FrameEndInfo{
            .display_time = frame_state.predicted_display_time,
            .environment_blend_mode = .@"opaque",
            .layer_count = @intCast(layers.len),
            .layers = @ptrCast(layers),
        };
        try xri.endFrame(xr_session, &frame_end_info);
    }
}
