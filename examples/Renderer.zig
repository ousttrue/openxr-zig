const xr = @import("openxr");
const xr_helper = @import("xr_helper.zig");

pub fn init() !@This()
{
    return .{
    };
}

pub fn deinit(_: *@This())void{
}

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
