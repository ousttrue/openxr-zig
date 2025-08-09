const xr = @import("openxr");
const xr_helper = @import("xr_helper.zig");

pub fn init() !@This()
{
    return .{
    };
}

pub fn deinit(_: *@This())void{
}

// const swapchain_formats_i64 = try allocator.alloc(i64, swapchain_format_count);
// defer allocator.free(swapchain_formats_i64);
// _ = try xri.enumerateSwapchainFormats(xr_session, swapchain_format_count, @ptrCast(swapchain_formats_i64));
// var swapchain_formats_vkformat = try allocator.alloc(vk.Format, swapchain_format_count);
// for (swapchain_formats_i64, 0..) |format, i| {
//     swapchain_formats_vkformat[i] = @as(vk.Format, @enumFromInt(@as(i32, @intCast(format))));
//     std.log.debug("  [{}] {}", .{ i, swapchain_formats_vkformat[i] });
// }
// .swapchain_formats = swapchain_formats_vkformat,

pub fn renderAndCompositLayers(_: *@This(), frame_state: xr.FrameState) []*const xr.CompositionLayerBaseHeader {
    if (frame_state.should_render == 0) {
        return &.{};
    }

    //     if (stereoscope.Locate(session, appSpace, frameState.predictedDisplayTime,
    //                            viewConfigurationType)) {
    //
    //       static XrTime init_time = -1;
    //       if (init_time < 0)
    //         init_time = frameState.predictedDisplayTime;
    //       auto elapsed_us = (frameState.predictedDisplayTime - init_time) / 1000;
    //
    //       for (uint32_t i = 0; i < stereoscope.views.size(); ++i) {
    //         // XrCompositionLayerProjectionView(left / right)
    //         auto swapchain = swapchains[i];
    //         auto [index, image, projectionLayer] =
    //             swapchain->AcquireSwapchain(stereoscope.views[i]);
    //         composition.pushView(projectionLayer);
    //
    //         engine.RenderLayer(frameState.predictedDisplayTime, elapsed_us, i,
    //                            projectionLayer,
    //                            stereoscope.views[i],
    //                            views[i]->backbuffers[index]->fbo.id);
    //
    //         swapchain->EndSwapchain();
    //       }
    //     }

    return &.{};
}
