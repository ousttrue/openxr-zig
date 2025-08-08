const xr = @import("openxr");

pub extern fn xrGetInstanceProcAddr(instance: xr.Instance, procname: [*:0]const u8, function: *xr.PfnVoidFunction) xr.Result;

const vk = @import("vulkan");
pub extern fn glfwInit() c_int;
pub extern fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;
