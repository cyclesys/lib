const std = @import("std");
const vk = @import("vulkan");
const tree = @import("../tree.zig");
const fns = @import("fns.zig");
const Target = @import("Target.zig");

allocator: std.mem.Allocator,

base_fns: fns.BaseFns,
instance: vk.Instance,
instance_fns: fns.InstanceFns,

physical_device: vk.PhysicalDevice,
physical_device_properties: vk.PhysicalDeviceProperties,
physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,

device: vk.Device,
device_fns: fns.DeviceFns,

graphics_queue_index: u32,
graphics_queue: vk.Queue,

command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,

pipeline: vk.Pipeline,

pub const DeviceId = [vk.UUID_SIZE]u8;
const Self = @This();

pub fn init(
    allocator: std.mem.Allocator,
    app_name: ?[:0]const u8,
    app_version: ?struct {
        variant: u32,
        major: u32,
        minor: u32,
        patch: u32,
    },
    dev_uuid: DeviceId,
) !Self {
    const loader = try fns.vulkanLoader();
    const base_fns = try fns.BaseFns.load(loader);

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
    const instance_fns = try fns.InstanceFns.load(instance, loader);

    const physical = try findPhysicalDevice(allocator, instance_fns, instance, dev_uuid);
    const device = try createDevice(instance_fns, physical.device, physical.graphics_queue_index);
    const device_fns = try fns.DeviceFns.load(device, instance_fns.dispatch.vkGetDeviceProcAddr);

    const graphics_queue = device_fns.getDeviceQueue(device, physical.graphics_queue_index, 0);

    const bp = try createCommandPoolAndBuffer(device_fns, device, physical.graphics_queue_index);

    return Self{
        .allocator = allocator,
        .base_fns = base_fns,
        .instance = instance,
        .instance_fns = instance_fns,
        .physical_device = physical.device,
        .physical_device_properties = physical.properties,
        .physical_device_memory_properties = physical.memory_properties,
        .device = device,
        .device_fns = device_fns,
        .graphics_queue_index = physical.graphics_queue_index,
        .graphics_queue = graphics_queue,
        .command_pool = bp.command_pool,
        .command_buffer = bp.command_buffer,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn render(self: *Self, render_tree: anytype, target: *Target) !void {
    _ = self;
    _ = render_tree;
    _ = target;
}

fn createInstance(
    allocator: std.mem.Allocator,
    base_fns: fns.BaseFns,
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
    instance_fns: fns.InstanceFns,
    instance: vk.Instance,
    uuid: DeviceId,
) !struct {
    device: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    graphics_queue_index: u32,
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

            const graphics_queue_index: u32 = blk: for (queue_families, 0..) |family, i| {
                if (family.queue_flags.graphics_bit) {
                    break :blk i;
                }
            } else {
                return error.VulkanDeviceInvalid;
            };

            const memory_properties = instance_fns.getPhysicalDeviceMemoryProperties(device);

            return .{
                .device = device,
                .properties = properties,
                .memory_properties = memory_properties,
                .graphics_queue_index = graphics_queue_index,
            };
        }
    }

    return error.VulkanDeviceNotFound;
}

fn createDevice(
    instance_fns: fns.InstanceFns,
    physical_device: vk.PhysicalDevice,
    graphics_queue_index: u32,
) !vk.Device {
    const priorities = [_]f32{1.0};
    const queue_create_infos = [_]vk.DeviceQueueCreateInfo{
        vk.DeviceQueueCreateInfo{
            .queue_family_index = graphics_queue_index,
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

fn createCommandPoolAndBuffer(device_fns: fns.DeviceFns, device: vk.Device, queue_family_index: u32) !struct {
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
} {
    const pool_create_info = vk.CommandPoolCreateInfo{
        .queue_family_index = queue_family_index,
    };
    const command_pool = try device_fns.createCommandPool(device, &pool_create_info, null);

    var buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    var command_buffer: vk.CommandBuffer = undefined;
    try device_fns.allocateCommandBuffers(device, &buffer_allocate_info, &command_buffer);

    return .{
        .command_pool = command_pool,
        .command_buffer = command_buffer,
    };
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
