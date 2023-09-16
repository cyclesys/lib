const vk = @import("vulkan");
const win32 = struct {
    const mod = @import("win32");
    usingnamespace mod.foundation;
    usingnamespace mod.system.library_loader;
};

var vulkan_lib: ?win32.HINSTANCE = null;
var vkGetInstanceProcAddr: ?win32.FARPROC = null;
pub fn vulkanLoader() !win32.FARPROC {
    if (vkGetInstanceProcAddr == null) {
        const vulkan_lib_name: [:0]const u8 = "vulkan-1.dll";
        vulkan_lib = win32.LoadLibraryA(@as([*]const u8, vulkan_lib_name));
        if (vulkan_lib == null) {
            return error.NoVulkanLib;
        }

        vkGetInstanceProcAddr = win32.GetProcAddress(
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
});
