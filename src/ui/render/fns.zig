const vk = @import("vulkan");
const win = @import("../../windows.zig");

var vulkan_lib: ?win.HINSTANCE = null;
var vkGetInstanceProcAddr: ?win.FARPROC = null;
pub fn vulkanLoader() !win.FARPROC {
    if (vkGetInstanceProcAddr == null) {
        const vulkan_lib_name: [:0]const u8 = "vulkan-1.dll";
        vulkan_lib = win.LoadLibraryA(@as([*]const u8, vulkan_lib_name));
        if (vulkan_lib == null) {
            return error.NoVulkanLib;
        }

        vkGetInstanceProcAddr = win.GetProcAddress(
            vulkan_lib,
            @as([:0]const u8, "vkGetInstanceProcAddr"),
        );
        if (vkGetInstanceProcAddr == null) {
            return error.InvalidVulkanLib;
        }
    }

    return vkGetInstanceProcAddr.?;
}

pub const BaseFns = vk.BaseWrapper(.{
    .createInstance = true,
});

pub const InstanceFns = vk.InstanceWrapper(.{
    .createDevice = true,
    .createDebugUtilsMessengerEXT = true,
    .destroyInstance = true,
    .destroySurfaceKHR = true,
});

pub const DeviceFns = vk.DeviceWrapper(.{
    .destroyDevice = true,

    .createCommandPool = true,
    .destroyCommandPool = true,
    .resetCommandPool = true,

    .allocateCommandBuffers = true,
    .freeCommandBuffers = true,
    .beginCommandBuffer = true,

    .queueSubmit = true,

    .createRenderPass = true,
    .destroyRenderPass = true,

    .createFramebuffer = true,
    .destroyFramebuffer = true,

    .cmdBeginRendering = true,
    .cmdEndRendering = true,

    .cmdBeginRenderPass = true,
    .cmdEndRenderPass = true,

    .createGraphicsPipeline = true,
    .destroyPipeline = true,
    .cmdBindPipeline = true,

    .createFence = true,
});
