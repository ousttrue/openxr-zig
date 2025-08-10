const c = @import("c.zig");
const std = @import("std");
const vk = @import("vulkan");

instance: vk.Instance,
vki: vk.InstanceWrapper,
device: vk.Device,
vkd: vk.DeviceWrapper,
queue_family_index: u32,
queue: vk.Queue,
pool: vk.CommandPool,

pub fn init(
    vk_instance: vk.Instance,
    vk_device: vk.Device,
    queue_family_index: u32,
) !@This() {
    const vki = vk.InstanceWrapper.load(vk_instance, c.glfwGetInstanceProcAddress);
    const vkd = vk.DeviceWrapper.load(vk_device, vki.dispatch.vkGetDeviceProcAddr.?);
    return @This(){
        .instance = vk_instance,
        .device = vk_device,
        .vki = vki,
        .vkd = vkd,
        .queue_family_index = queue_family_index,
        .queue = vkd.getDeviceQueue(vk_device, queue_family_index, 0),
        .pool = try vkd.createCommandPool(
            vk_device,
            &.{
                .flags = .{
                    .transient_bit = true,
                    .reset_command_buffer_bit = true,
                },
                .queue_family_index = queue_family_index,
            },
            null,
        ),
    };
}

pub fn deinit(self: *@This()) void {
    self.vkd.destroyCommandPool(self.device, self.pool, null);
}

pub fn render(self: *@This(), image: vk.Image, clear_color_value: vk.ClearColorValue) !void {
    var cmd: vk.CommandBuffer = undefined;
    try self.vkd.allocateCommandBuffers(self.device, &.{
        .command_pool = self.pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmd));
    defer self.vkd.freeCommandBuffers(self.device, self.pool, 1, @ptrCast(&cmd));

    const submit_fence = try self.vkd.createFence(self.device, &.{
        .flags = .{},
    }, null);
    defer self.vkd.destroyFence(self.device, submit_fence, null);

    // make command buffer. begin to end
    {
        const image_subresource_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };

        try self.vkd.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });
        defer self.vkd.endCommandBuffer(cmd) catch @panic("OOP");

        self.vkd.cmdPipelineBarrier(
            cmd,
            .{ .transfer_bit = true },
            .{ .transfer_bit = true },
            .{},
            0,
            null,
            0,
            null,
            1,
            &[1]vk.ImageMemoryBarrier{
                .{
                    .src_access_mask = .{ .memory_read_bit = true },
                    .dst_access_mask = .{ .transfer_write_bit = true },
                    .old_layout = .undefined,
                    .new_layout = .transfer_dst_optimal,
                    .src_queue_family_index = self.queue_family_index,
                    .dst_queue_family_index = self.queue_family_index,
                    .image = image,
                    .subresource_range = image_subresource_range,
                },
            },
        );

        self.vkd.cmdClearColorImage(
            cmd,
            image,
            .transfer_dst_optimal,
            &clear_color_value,
            1,
            @ptrCast(&image_subresource_range),
        );

        self.vkd.cmdPipelineBarrier(
            cmd,
            .{ .transfer_bit = true },
            .{ .bottom_of_pipe_bit = true },
            .{},
            0,
            null,
            0,
            null,
            1,
            &[1]vk.ImageMemoryBarrier{
                .{
                    .src_access_mask = .{ .transfer_write_bit = true },
                    .dst_access_mask = .{ .memory_read_bit = true },
                    .old_layout = .transfer_dst_optimal,
                    .new_layout = .present_src_khr,
                    .src_queue_family_index = self.queue_family_index,
                    .dst_queue_family_index = self.queue_family_index,
                    .image = image,
                    .subresource_range = image_subresource_range,
                },
            },
        );
    }

    // submit
    try self.vkd.queueSubmit(
        self.queue,
        1,
        &[1]vk.SubmitInfo{
            .{
                .wait_semaphore_count = 0,
                .p_wait_semaphores = null,
                .p_wait_dst_stage_mask = &[1]vk.PipelineStageFlags{
                    .{
                        .transfer_bit = true,
                        .color_attachment_output_bit = true,
                    },
                },
                .command_buffer_count = 1,
                .p_command_buffers = &[1]vk.CommandBuffer{cmd},
                .signal_semaphore_count = 0,
                .p_signal_semaphores = null,
            },
        },
        submit_fence,
    );

    _ = try self.vkd.waitForFences(self.device, 1, @ptrCast(&submit_fence), 1, std.math.maxInt(u64));
}
