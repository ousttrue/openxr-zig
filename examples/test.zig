const c = @import("c.zig");
const std = @import("std");
const xr = @import("openxr");
const vk = @import("vulkan");

const xrBaseDispatch = xr.BaseWrapper(.{
    .createInstance = true,
});

const xrInstanceDispatch = xr.InstanceWrapper(.{
    .destroyInstance = true,
    .getSystem = true,
    .getSystemProperties = true,
    .createSession = true,
    .pollEvent = true,
    .getInstanceProperties = true,
    // vulkan
    .getVulkanGraphicsRequirements2KHR = true,
    .createVulkanInstanceKHR = true,
    .getVulkanGraphicsDevice2KHR = true,
});

var g_pfn: xr.PFN_vkGetInstanceProcAddr = undefined;
fn vkGetInstanceProcAddr(
    instance: vk.Instance,
    p_name: [*:0]const u8,
) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    // std.log.debug("call: vkGetInstanceProcAddr: {}, {s}", .{ instance, p_name });
    // return g_pfn(instance, p_name);
    return c.glfwGetInstanceProcAddress(instance, p_name);
}

pub fn main() !void {
    if (c.glfwInit() == 0) {
        @panic("OOP");
    }

    var name: [128]u8 = undefined;
    std.mem.copyForwards(u8, name[0..], "openxr-zig-test" ++ [_]u8{0});

    const xrb = try xrBaseDispatch.load(c.xrGetInstanceProcAddr);

    const inst = try xrb.createInstance(&.{
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

    const xri = try xrInstanceDispatch.load(inst, c.xrGetInstanceProcAddr);
    defer xri.destroyInstance(inst) catch unreachable;
    var instance_properties = xr.InstanceProperties.empty();
    try xri.getInstanceProperties(inst, &instance_properties);
    std.log.debug("runtimeName: {s}", .{std.mem.sliceTo(&instance_properties.runtime_name, 0)});

    const system = try xri.getSystem(inst, &.{ .form_factor = .head_mounted_display });
    var system_properties = xr.SystemProperties.empty();
    try xri.getSystemProperties(inst, system, &system_properties);
    std.log.debug("systemName: {s}", .{std.mem.sliceTo(&system_properties.system_name, 0)});

    var graphicsRequirements = xr.GraphicsRequirementsVulkan2KHR.empty();
    try xri.getVulkanGraphicsRequirements2KHR(inst, system, &graphicsRequirements);

    const appInfo = vk.ApplicationInfo{
        .p_application_name = "hello_xr",
        .application_version = 1,
        .p_engine_name = "hello_xr",
        .engine_version = 1,
        .api_version = @bitCast(vk.API_VERSION_1_0),
    };

    const instInfo = vk.InstanceCreateInfo{
        .p_application_info = &appInfo,
        // .enabledLayerCount = static_cast<uint32_t>(instance.layers.size()),
        // .ppEnabledLayerNames = instance.layers.data(),
        // .enabledExtensionCount = static_cast<uint32_t>(instance.extensions.size()),
        // .ppEnabledExtensionNames = instance.extensions.data(),
    };

    //
    // vulkan
    //
    const createInfo = xr.VulkanInstanceCreateInfoKHR{
        .system_id = system,
        .pfn_get_instance_proc_addr = vkGetInstanceProcAddr,
        .vulkan_create_info = &instInfo,
    };

    // VkInstance
    var vkInstance: vk.Instance = undefined;
    var result: vk.Result = undefined;
    try xri.createVulkanInstanceKHR(inst, &createInfo, &vkInstance, &result);
    const vki = vk.InstanceWrapper.load(vkInstance, c.glfwGetInstanceProcAddress);

    // VkPhysicalDevice
    const deviceGetInfo = xr.VulkanGraphicsDeviceGetInfoKHR{
        .system_id = system,
        .vulkan_instance = vkInstance,
    };
    var vkPhysicalDevice: vk.PhysicalDevice = undefined;
    try xri.getVulkanGraphicsDevice2KHR(inst, &deviceGetInfo, &vkPhysicalDevice);
    const physicalDeviceProps = vki.getPhysicalDeviceProperties(vkPhysicalDevice);
    std.log.debug("vulkan: physicalDeviceName: {s}", .{physicalDeviceProps.device_name});

    // _ = try xri.createSession(inst, &.{
    //     .system_id = system,
    // });
}
