const std = @import("std");
const xr = @import("openxr");
const xr_helper = @import("xr_helper.zig");

allocator: std.mem.Allocator,
xri: *const xr_helper.XrInstanceDispatch,
xr_instance: xr.Instance,
xr_session: xr.Session,
xr_view_configuration_type: xr.ViewConfigurationType,
xr_session_state: xr.SessionState = .unknown,
exit_requested: bool = false,
session_running: bool = false,
exit_renderloop: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    xri: *const xr_helper.XrInstanceDispatch,
    xr_instance: xr.Instance,
    xr_session: xr.Session,
    xr_view_configuration_type: xr.ViewConfigurationType,
) !@This() {
    return .{
        .allocator = allocator,
        .xri = xri,
        .xr_instance = xr_instance,
        .xr_session = xr_session,
        .xr_view_configuration_type = xr_view_configuration_type,
    };
}

pub fn deinit(_: *@This()) void {
}

pub fn canRendering(self: *const @This()) bool {
    return !self.exit_requested and self.session_running;
}

pub fn pollEvents(self: *@This()) !bool {
    while (true) {
        var eventbuffer = xr.EventDataBuffer.empty();
        const result = try self.xri.pollEvent(self.xr_instance, &eventbuffer);
        switch (result) {
            .success => {
                const event: *const xr.EventDataBaseHeader = @ptrCast(&eventbuffer);
                switch (event.type) {
                    .event_data_events_lost => {
                        //   const XrEventDataEventsLost *const eventsLost =
                        //       reinterpret_cast<const XrEventDataEventsLost *>(event);
                        //   Logger::Error("%d events lost", eventsLost->lostEventCount);
                        //   break;
                    },
                    .event_data_instance_loss_pending => {
                        //   const auto &instanceLossPending =
                        //       *reinterpret_cast<const XrEventDataInstanceLossPending *>(event);
                        //   Logger::Error("XrEventDataInstanceLossPending by %lld",
                        //                 instanceLossPending.lossTime);
                        //   this->m_exitRenderLoop = true;
                        //   this->m_requestRestart = true;
                        //   return;
                    },
                    .event_data_session_state_changed => {
                        // *reinterpret_cast<const XrEventDataSessionStateChanged *>(
                        try self.handleSessionStateChangedEvent(@ptrCast(event));
                    },
                    .event_data_interaction_profile_changed => {
                        // m_input.Log(m_session);
                    },
                    else => {
                        std.log.info("Ignoring event type {}", .{event.type});
                    },
                }
            },
            .event_unavailable => {
                // break poll events
                break;
            },
            else => {
                @panic("xrPollEvent");
            },
        }
    }

    return !self.exit_requested;
}

fn handleSessionStateChangedEvent(
    self: *@This(),
    event: *const xr.EventDataSessionStateChanged,
) !void {
    const oldState = self.xr_session_state;
    self.xr_session_state = event.state;

    std.log.info(
        "XrEventDataSessionStateChanged: state {s}->{s} session = {} time={}",
        .{
            @tagName(oldState),
            @tagName(self.xr_session_state),
            event.session,
            event.time,
        },
    );

    if ((event.session != .null_handle) and
        (event.session != self.xr_session))
    {
        std.log.err("XrEventDataSessionStateChanged for unknown session", .{});
        return;
    }

    switch (self.xr_session_state) {
        .ready => {
            std.debug.assert(self.xr_session != .null_handle);
            const session_begin_info = xr.SessionBeginInfo{
                .primary_view_configuration_type = self.xr_view_configuration_type,
            };
            try self.xri.beginSession(self.xr_session, &session_begin_info);
            self.session_running = true;
        },
        .stopping => {
            std.debug.assert(self.xr_session != .null_handle);
            self.session_running = false;
            try self.xri.endSession(self.xr_session);
        },
        .exiting => {
            self.exit_requested = true;
            // Do not attempt to restart because user closed this session.
        },
        .loss_pending => {
            // Poll for a new instance.
        },
        else => {},
    }
}
