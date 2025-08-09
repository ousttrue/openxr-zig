const std = @import("std");
const xr = @import("openxr");
const vk = @import("vulkan");

pub const XrBaseDispatch = xr.BaseWrapper(.{
    .createInstance = true,
});

pub const XrInstanceDispatch = xr.InstanceWrapper(.{
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
    .createVulkanDeviceKHR = true,
    // session
    .beginSession = true,
    .endSession = true,
    .waitFrame = true,
    .beginFrame = true,
    .endFrame = true,
    // view
    .createReferenceSpace = true,
    .enumerateViewConfigurationViews = true,
    .locateViews = true,
    // swapchain
    .enumerateSwapchainFormats = true,
});
