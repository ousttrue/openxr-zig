const std = @import("std");
const xr = @import("openxr");
const vk = @import("vulkan");
const xr_helper = @import("xr_helper.zig");

allocator: std.mem.Allocator,
xri: *const xr_helper.XrInstanceDispatch,
swapchain_create_info: xr.SwapchainCreateInfo,
swapchain: xr.Swapchain,
images: []xr.SwapchainImageVulkan2KHR,

pub fn init(
    allocator: std.mem.Allocator,
    xri: *const xr_helper.XrInstanceDispatch,
    xr_session: xr.Session,
    format: vk.Format,
    vp: xr.ViewConfigurationView,
) !@This() {
    const swapchain_create_info = xr.SwapchainCreateInfo{
        .usage_flags = .{
            .sampled_bit = true,
            .color_attachment_bit = true,
        },
        .format = @intFromEnum(format),
        .sample_count = 1,
        .width = vp.recommended_image_rect_width,
        .height = vp.recommended_image_rect_width,
        .face_count = 1,
        .array_size = 1,
        .mip_count = 1,
    };
    const swapchain = try xri.createSwapchain(xr_session, &swapchain_create_info);

    const image_count = try xri.enumerateSwapchainImages(swapchain, 0, null);
    std.log.debug("swapchain image_count: {}", .{image_count});
    const images = try allocator.alloc(xr.SwapchainImageVulkan2KHR, image_count);
    for (0..image_count) |i| {
        images[i] = xr.SwapchainImageVulkan2KHR.empty();
    }
    _ = try xri.enumerateSwapchainImages(swapchain, image_count, @ptrCast(&images[0]));
    for (images, 0..) |image, i| {
        std.log.debug("  [{}] {}", .{ i, image.image });
    }

    return .{
        .xri = xri,
        .allocator = allocator,
        .swapchain_create_info = swapchain_create_info,
        .swapchain = swapchain,
        .images = images,
    };
}

pub fn deinit(self: *@This()) void {
    self.allocator.free(self.images);
}

pub const Acquired = struct {
    image_index: u32,
    image: xr.SwapchainImageVulkan2KHR,
    projection_view: xr.CompositionLayerProjectionView,
};

pub fn acquireSwapchain(self: *@This(), view: *const xr.View) !Acquired {
    const acquire_info = xr.SwapchainImageAcquireInfo.empty();
    const swapchain_image_index = try self.xri.acquireSwapchainImage(self.swapchain, &acquire_info);

    const waitInfo = xr.SwapchainImageWaitInfo{
        .timeout = 0x7fffffffffffffff, //XR_INFINITE_DURATION,
    };
    const result = try self.xri.waitSwapchainImage(self.swapchain, &waitInfo);
    std.debug.assert(result == .success);

    return .{
        .image_index = swapchain_image_index,
        .image = self.images[swapchain_image_index],
        .projection_view = .{
            .pose = view.pose,
            .fov = view.fov,
            .sub_image = .{
                .image_array_index = 0,
                .swapchain = self.swapchain,
                .image_rect = .{
                    .offset = .{},
                    .extent = .{
                        .width = @intCast(self.swapchain_create_info.width),
                        .height = @intCast(self.swapchain_create_info.height),
                    },
                },
            },
        },
    };
}

pub fn endSwapchain(self: *@This()) !void {
    const releaseInfo = xr.SwapchainImageReleaseInfo.empty();
    try self.xri.releaseSwapchainImage(self.swapchain, &releaseInfo);
}
