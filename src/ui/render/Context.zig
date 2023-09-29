const std = @import("std");
const vk = @import("vulkan");
const shaders = @import("shaders");
const win = @import("../../windows.zig");

base_fns: BaseFns,
instance: vk.Instance,
instance_fns: InstanceFns,

physical_device: vk.PhysicalDevice,
host_visible_memory_index: u32,
device_local_memory_index: u32,

device: vk.Device,
device_fns: DeviceFns,

queue_family_index: u32,

pub const AppVersion = struct {
    variant: u32,
    major: u32,
    minor: u32,
    patch: u32,
};
pub const DeviceId = [vk.UUID_SIZE]u8;
const Self = @This();

pub fn init(
    allocator: std.mem.Allocator,
    app_name: [*:0]const u8,
    app_version: ?AppVersion,
    dev_uuid: DeviceId,
) !Self {
    const loader = try vulkanLoader();
    const base_fns = try BaseFns.load(loader);

    const instance = try createInstance(
        allocator,
        base_fns,
        if (app_name) |n|
            @ptrCast(n)
        else
            "cycle plugin",
        if (app_version) |v|
            vk.makeApiVersion(v.variant, v.major, v.minor, v.patch)
        else
            vk.makeApiVersion(0, 0, 1, 0),
    );
    const instance_fns = try InstanceFns.load(instance, loader);

    const physical_device, const physical_device_memory_properties, const queue_family_index = try findPhysicalDevice(allocator, instance_fns, instance, dev_uuid);

    const host_visible_memory_index = try findMemoryTypeIndex(physical_device_memory_properties, true);
    const device_local_memory_index = try findMemoryTypeIndex(physical_device_memory_properties, false);

    const device = try createDevice(instance_fns, physical_device, queue_family_index);
    const device_fns = try DeviceFns.load(device, instance_fns.dispatch.vkGetDeviceProcAddr);

    return Self{
        .base_fns = base_fns,
        .instance = instance,
        .instance_fns = instance_fns,
        .physical_device = physical_device,
        .host_visible_memory_index = host_visible_memory_index,
        .device_local_memory_index = device_local_memory_index,
        .device = device,
        .device_fns = device_fns,
        .queue_family_index = queue_family_index,
    };
}

pub fn deinit(self: Self) void {
    self.device_fns.destroyDevice(self.device, null);
}

fn createInstance(
    allocator: std.mem.Allocator,
    base_fns: BaseFns,
    app_name: [*:0]const u8,
    app_version: u32,
) !vk.Instance {
    var extension_count: u32 = 0;
    _ = try base_fns.enumerateInstanceExtensionProperties(null, &extension_count, null);

    const extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
    defer allocator.free(extensions);

    _ = try base_fns.enumerateInstanceExtensionProperties(null, &extension_count, extensions.ptr);

    if (!required_extensions.contains(extensions))
        return error.VulkanExtensionsNotSupported;

    const instance = try base_fns.createInstance(&.{
        .p_application_info = &vk.ApplicationInfo{
            .p_application_name = app_name,
            .application_version = app_version,
            .p_engine_name = @as([*:0]const u8, "cycle.Renderer"),
            .engine_version = vk.makeApiVersion(0, 0, 1, 0),
            .api_version = vk.API_VERSION_1_3,
        },
        .enabled_extension_count = required_extensions.names.len,
        .pp_enabled_extension_names = &required_extensions.names,
    });

    return instance;
}

fn findPhysicalDevice(
    allocator: std.mem.Allocator,
    instance_fns: InstanceFns,
    instance: vk.Instance,
    uuid: DeviceId,
) !struct {
    vk.PhysicalDevice,
    vk.PhysicalDeviceMemoryProperties,
    u32,
} {
    var device_count: u32 = 0;
    _ = try instance_fns.enumeratePhysicalDevices(instance, &device_count, null);

    const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(devices);

    _ = try instance_fns.enumeratePhysicalDevices(instance, &device_count, devices.ptr);

    for (devices) |device| {
        const properties = instance_fns.getPhysicalDeviceProperties(device);

        if (std.mem.eql(u8, properties.pipeline_cache_uuid, uuid)) {
            var queue_family_count: u32 = 0;
            instance_fns.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

            const queue_families = try allocator.alloc(vk.QueueFamilyProperties, queue_family_count);
            defer allocator.free(queue_families);

            instance_fns.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

            const queue_family_index: u32 = blk: for (queue_families, 0..) |family, i| {
                if (family.queue_flags.graphics_bit) {
                    break :blk i;
                }
            } else {
                return error.VulkanDeviceInvalid;
            };

            const memory_properties = instance_fns.getPhysicalDeviceMemoryProperties(device);

            return .{
                device,
                memory_properties,
                queue_family_index,
            };
        }
    }

    return error.VulkanDeviceNotFound;
}

fn findMemoryTypeIndex(props: vk.PhysicalDeviceMemoryProperties, host_visible: bool) !u32 {
    for (0..props.memory_type_count) |i| {
        const mem_type = props.memory_types[i];
        if (host_visible) {
            if (mem_type.property_flags.host_visible_bit) {
                return i;
            }
        } else if (mem_type.property_flags.device_local_bit) {
            return i;
        }
    }
    return error.MemoryTypeNotAvailable;
}

fn createDevice(
    instance_fns: InstanceFns,
    physical_device: vk.PhysicalDevice,
    queue_family_index: u32,
) !vk.Device {
    const priorities = [_]f32{1.0};
    const queue_create_infos = [_]vk.DeviceQueueCreateInfo{
        vk.DeviceQueueCreateInfo{
            .queue_family_index = queue_family_index,
            .queue_count = 1,
            .p_queue_priorities = &priorities,
        },
    };

    const device = instance_fns.createDevice(
        physical_device,
        &vk.DeviceCreateInfo{
            .queue_create_info_count = queue_create_infos.len,
            .p_queue_create_infos = &queue_create_infos,
        },
        null,
    );

    return device;
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

    .createImage = true,
    .destroyImage = true,
    .bindImageMemory = true,

    .createRenderPass = true,
    .destroyRenderPass = true,

    .createFramebuffer = true,
    .destroyFramebuffer = true,

    .cmdBeginRendering = true,
    .cmdEndRendering = true,

    .cmdBeginRenderPass = true,
    .cmdEndRenderPass = true,

    .createDescriptorSetLayout = true,
    .destroyDescriptorSetLayout = true,

    .createPipelineLayout = true,
    .destroyPipelineLayout = true,

    .createShaderModule = true,
    .destroyShaderModule = true,

    .createGraphicsPipelines = true,
    .destroyPipeline = true,
    .cmdBindPipeline = true,

    .createFence = true,
    .destroyFence = true,
});

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

const required_extensions = struct {
    const names = .{
        @as([:0]const u8, "VK_KHR_external_memory_win32"),
    };

    fn contains(extensions: []const vk.ExtensionProperties) bool {
        outer: for (names) |req| {
            for (extensions) |ext| {
                const extension_name = std.mem.sliceTo(&ext.extension_name, 0);
                if (std.mem.eql(u8, extension_name, req.?)) {
                    continue :outer;
                }
            } else {
                return false;
            }
        }

        return true;
    }
};
