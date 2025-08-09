const std = @import("std");
const xr = @import("openxr");
const xr_helper = @import("xr_helper.zig");

xri: *const xr_helper.XrInstanceDispatch,
xr_instance: xr.Instance,
xr_session: xr.Session,
xr_system_id: xr.SystemId,
view_configuration_type: xr.ViewConfigurationType,

view_configurations: [2]xr.ViewConfigurationView = .{
    xr.ViewConfigurationView.empty(),
    xr.ViewConfigurationView.empty(),
},
views: [2]xr.View = .{
    xr.View.empty(),
    xr.View.empty(),
},

pub fn init(
    xri: *const xr_helper.XrInstanceDispatch,
    xr_instance: xr.Instance,
    xr_system_id: xr.SystemId,
    xr_session: xr.Session,
    view_configuration_type: xr.ViewConfigurationType,
) !@This() {
    var self = @This(){
        .xri = xri,
        .xr_instance = xr_instance,
        .xr_system_id = xr_system_id,
        .xr_session = xr_session,
        .view_configuration_type = view_configuration_type,
    };

    // Query and cache view configuration views.
    const view_count = try xri.enumerateViewConfigurationViews(
        xr_instance,
        xr_system_id,
        view_configuration_type,
        self.view_configurations.len,
        &self.view_configurations,
    );
    std.debug.assert(view_count == 2);

    std.log.debug("xr.ViewConfigurationView[{}]", .{view_count});
    for (self.view_configurations, 0..view_count) |vp, i| {
        std.log.debug(
            "  [{}/{}]: MaxWH({}, {}), MaxSample({}), RecWH({}, {}), RecSample({})",
            .{
                i,
                view_count,
                vp.max_image_rect_width,
                vp.max_image_rect_height,
                vp.max_swapchain_sample_count,
                vp.recommended_image_rect_width,
                vp.recommended_image_rect_height,
                vp.recommended_swapchain_sample_count,
            },
        );
    }

    return self;
}

pub fn deinit(_: *@This()) void {}

pub fn locate(self: *@This(), space: xr.Space, predicted_display_time: xr.Time) !bool {
    const view_locate_info = xr.ViewLocateInfo{
        .view_configuration_type = self.view_configuration_type,
        .display_time = predicted_display_time,
        .space = space,
    };

    var view_state = xr.ViewState.empty();

    const view_count_output = try self.xri.locateViews(
        self.xr_session,
        &view_locate_info,
        &view_state,
        self.views.len,
        &self.views,
    );
    if (!view_state.view_state_flags.position_valid_bit or
        !view_state.view_state_flags.orientation_valid_bit)
    {
        return false; // There is no valid tracking poses for the views.
    }

    std.debug.assert(view_count_output == 2);
    return true;
}
