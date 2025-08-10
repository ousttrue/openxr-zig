const std = @import("std");
const xr = @import("openxr");
const vk = @import("vulkan");
const c = @import("c.zig");
const xr_helper = @import("xr_helper.zig");

pub const Graphics = struct {
    instance: vk.Instance,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    queue_family_index: u32,
    binding: xr.GraphicsBindingVulkan2KHR,
};

pub fn init(
    xri: *const xr_helper.XrInstanceDispatch,
    xr_instance: xr.Instance,
    xr_system_id: xr.SystemId,
) !Graphics {
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
    // create vulkan by XrInstance [XR_KHR_vulkan_enable2]
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

    const xr_graphics_binding = xr.GraphicsBindingVulkan2KHR{
        .instance = vk_instance,
        .physical_device = vk_physical_device,
        .device = vk_device,
        .queue_family_index = queue_family_index,
        .queue_index = 0,
    };

    return .{
        .instance = vk_instance,
        .physical_device = vk_physical_device,
        .device = vk_device,
        .queue_family_index = queue_family_index,
        .binding = xr_graphics_binding,
    };
}

fn selectQueueFamily(
    allocator: std.mem.Allocator,
    vki: *const vk.InstanceWrapper,
    vk_physical_device: vk.PhysicalDevice,
) !?u32 {
    var queue_family_count: u32 = 0;
    vki.getPhysicalDeviceQueueFamilyProperties(vk_physical_device, &queue_family_count, null);
    std.log.debug("vk.QueueFamilyProperties[{}]", .{queue_family_count});
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

pub fn selectSwapchainFormat(
    allocator: std.mem.Allocator,
    xri: *const xr_helper.XrInstanceDispatch,
    xr_session: xr.Session,
) !vk.Format {
    // Select a swapchain format.
    const swapchain_format_count = try xri.enumerateSwapchainFormats(xr_session, 0, null);

    const swapchain_formats_i64 = try allocator.alloc(i64, swapchain_format_count);
    defer allocator.free(swapchain_formats_i64);
    _ = try xri.enumerateSwapchainFormats(xr_session, swapchain_format_count, @ptrCast(swapchain_formats_i64));

    // List of supported color swapchain formats.
    const candidates = [_]vk.Format{
        vk.Format.b8g8r8a8_srgb,
        vk.Format.r8g8b8a8_srgb,
        vk.Format.b8g8r8a8_unorm,
        vk.Format.r8g8b8a8_unorm,
    };

    for (swapchain_formats_i64) |format| {
        const vkformat = @as(vk.Format, @enumFromInt(@as(i32, @intCast(format))));
        for (candidates) |candidate| {
            if (vkformat == candidate) {
                std.log.debug("swapchain format => {s}", .{@tagName(vkformat)});
                return vkformat;
            }
        }
    }
    @panic("not found");
}
