const std = @import("std");
const vk = @import("vulkan");
const win32 = struct {
    const mod = @import("win32");
    usingnamespace mod.foundation;
    usingnamespace mod.system.library_loader;
};
const super = @import("../render.zig");

var vulkan_lib: ?win32.HINSTANCE = null;
var vkGetInstanceProcAddr: ?win32.FARPROC = null;
pub fn vulkanLoader() !win32.FARPROC {
    if (vkGetInstanceProcAddr == null) {
        const vulkan_lib_name: [:0]const u8 = "vulkan-1.dll";
        vulkan_lib = win32.LoadLibraryA(@as([*]const u8, vulkan_lib_name));
        if (vulkan_lib == null) {
            return error.VulkanLibNotLoaded;
        }

        vkGetInstanceProcAddr = win32.GetProcAddress(
            vulkan_lib,
            @as([:0]const u8, "vkGetInstanceProcAddr"),
        );
        if (vkGetInstanceProcAddr == null) {
            return error.VulkanLibInvalid;
        }
    }

    return vkGetInstanceProcAddr.?;
}

pub const RenderTarget = struct {
    memory: vk.DeviceMemory,
    image: vk.Image,
    image_view: vk.ImageView,

    pub fn create(
        dis: anytype,
        dev: vk.Device,
        mem_type_idx: u32,
        format: vk.Format,
        queue: u32,
        width: u32,
        height: u32,
    ) !RenderTarget {
        const iv = try createImageAndView(
            dis,
            dev,
            format,
            queue,
            width,
            height,
            vk.ImageUsageFlags{
                .sampled_bit = true,
                .input_attachment_bit = true,
            },
        );

        const memory = try dis.allocateMemory(
            dev,
            &vk.MemoryAllocateInfo{
                .p_next = &vk.ExportMemoryAllocateInfo{
                    .handle_types = vk.ExternalMemoryHandleTypeFlags{ .opaque_win32_bit = true },
                },
                .allocation_size = iv.reqs.size,
                .memory_type_index = mem_type_idx,
            },
            null,
        );

        return RenderTarget{
            .memory = memory,
            .image = iv.image,
            .view = iv.view,
        };
    }

    pub fn exportMemory(
        self: *RenderTarget,
        dis: anytype,
        dev: vk.Device,
    ) !win32.HANDLE {
        var handle: win32.HANDLE = undefined;
        try dis.getMemoryWin32HandleKHR(
            dev,
            &vk.MemoryGetWin32HandleInfoKHR{
                .memory = self.memory,
                .handle_type = vk.ExternalMemoryHandleTypeFlags{ .opaque_win32_bit = true },
            },
            &handle,
        );
        return handle;
    }

    pub fn import(
        dis: DeviceDispatch,
        dev: vk.Device,
        mem_type_idx: u32,
        format: vk.Format,
        queue: u32,
        width: u32,
        height: u32,
        handle: win32.HANDLE,
    ) !RenderTarget {
        const iv = try createImageAndView(
            dis,
            dev,
            format,
            queue,
            width,
            height,
            vk.ImageUsageFlags{ .color_attachment_bit = true },
        );

        const memory = try dis.allocateMemory(
            dev,
            &vk.MemoryAllocateInfo{
                .p_next = &vk.ImportMemoryWin32HandleInfoKHR{
                    .handle_type = vk.ExternalMemoryHandleTypeFlags{ .opaque_win32_bit = true },
                    .handle = handle,
                    .name = null,
                },
                .allocation_size = iv.reqs.size,
                .memory_type_index = mem_type_idx,
            },
            null,
        );

        return RenderTarget{
            .memory = memory,
            .image = iv.image,
            .view = iv.view,
        };
    }
};

fn createImageAndView(
    dis: anytype,
    dev: vk.Device,
    format: vk.Format,
    queue: u32,
    width: u32,
    height: u32,
    usage: vk.ImageUsageFlags,
) !struct {
    image: vk.Image,
    view: vk.ImageView,
    reqs: vk.MemoryRequirements,
} {
    const image = try dis.createImage(
        dev,
        &vk.ImageCreateInfo{
            .flags = vk.ImageCreateFlags{ .@"2d_array_compatible_bit" = true },
            .image_type = .@"2d",
            .format = format,
            .extent = vk.Extent3D{
                .width = width,
                .height = height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .@"1_bit",
            .tiling = .optimal,
            .usage = usage,
            .sharing_mode = .exclusive,
            .queue_family_index_count = 1,
            .p_queue_family_indices = &queue,
            .initial_layout = .undefined,
        },
        null,
    );

    const view = try dis.createImageView(
        dev,
        &vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = vk.ComponentMapping{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresources_range = vk.ImageSubresourceRange{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        },
        null,
    );

    const reqs = dis.getImageMemoryRequirements(dev, image);

    return .{
        image,
        view,
        reqs,
    };
}

const DeviceId = [vk.UUID_SIZE]u8;

const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
});

const InstanceDispatch = vk.InstanceWrapper(.{
    .createDevice = true,
    .createDebugUtilsMessengerEXT = true,
    .destroyInstance = true,
    .destroySurfaceKHR = true,
});

const DeviceDispatch = vk.DeviceWrapper(.{
    .destroyDevice = true,
});

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

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    format: vk.Format,

    dis: struct {
        base: BaseDispatch,
        ins: InstanceDispatch,
        dev: DeviceDispatch,
    },
    instance: vk.Instance,
    phy: struct {
        dev: vk.PhysicalDevice,
        props: vk.PhysicalDeviceProperties,
        mem_props: vk.PhysicalDeviceMemoryProperties,
    },
    dev: vk.Device,
    q: struct {
        idx: u32,
        handle: vk.Queue,
    },

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
    ) !Renderer {
        const loader = try vulkanLoader();
        const base_dis = try BaseDispatch.load(loader);

        const instance = try createInstance(
            allocator,
            base_dis,
            if (app_name) |n|
                @ptrCast([*:0]const u8, n)
            else
                @as([*:0]const u8, "cycle plugin"),
            if (app_version) |v|
                vk.makeApiVersion(v.variant, v.major, v.minor, v.patch)
            else
                vk.makeApiVersion(0, 0, 1, 0),
        );
        const ins_dis = try InstanceDispatch.load(instance, loader);

        const phy = try findPhysicalDevice(allocator, instance, ins_dis, dev_uuid);
        const dev = try createDevice(ins_dis, phy.dev, phy.gfx);
        const dev_dis = try DeviceDispatch.load(dev, ins_dis.dispatch.vkGetDeviceProcAddr);

        const q_handle = dev_dis.getDeviceQueue(dev, phy.q_idx, 0);

        return Renderer{
            .allocator = allocator,
            .dis = .{
                .base = base_dis,
                .ins = ins_dis,
                .dev = dev_dis,
            },
            .instance = instance,
            .phy = .{
                .dev = phy.dev,
                .props = phy.props,
                .mem_props = phy.mem_props,
            },
            .q = .{
                .idx = phy.q_idx,
                .handle = q_handle,
            },
        };
    }

    pub fn render(self: *Renderer, layers: []const super.Layer, target: *RenderTarget) !void {
        _ = self;
        _ = layers;
        _ = target;
    }
};

fn createInstance(
    allocator: std.mem.Allocator,
    dis: BaseDispatch,
    app_name: [*:0]const u8,
    app_version: u32,
) !vk.Instance {
    var extension_count: u32 = 0;
    _ = try dis.enumerateInstanceExtensionProperties(null, &extension_count, null);

    const extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
    defer allocator.free(extensions);

    _ = try dis.enumerateInstanceExtensionProperties(null, &extension_count, extensions.ptr);

    if (!required_extensions.contains(extensions))
        return error.VulkanExtensionsNotSupported;

    const instance = try dis.createInstance(&.{
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
    instance: vk.Instance,
    dis: InstanceDispatch,
    uuid: DeviceId,
) !struct {
    dev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    q_idx: u32,
} {
    var dev_count: u32 = 0;
    _ = try dis.enumeratePhysicalDevices(instance, &dev_count, null);

    const devs = try allocator.alloc(vk.PhysicalDevice, dev_count);
    defer allocator.free(devs);

    _ = try dis.enumeratePhysicalDevices(instance, &dev_count, devs.ptr);

    for (0..dev_count) |i| {
        const dev = devs[i];
        const props = dis.getPhysicalDeviceProperties(dev);

        if (std.mem.eql(u8, props.pipeline_cache_uuid, uuid)) {
            var queue_family_count: u32 = 0;
            _ = try dis.getPhysicalDeviceQueueFamilyProperties(dev, &queue_family_count, null);

            const queue_families = try allocator.alloc(vk.QueueFamilyProperties, queue_family_count);
            defer allocator.free(queue_families);

            _ = try dis.getPhysicalDeviceQueueFamilyProperties(dev, &queue_family_count, queue_families.ptr);

            const q_idx: u32 = blk: for (queue_families, 0..) |family, ii| {
                if (family.queue_flags.graphics_bit) {
                    break :blk ii;
                }
            } else {
                return error.VulkanDeviceInvalid;
            };

            const mem_props = dis.getPhysicalDeviceMemoryProperties(dev);

            return .{
                dev,
                props,
                mem_props,
                q_idx,
            };
        }
    }

    return error.VulkanDeviceNotFound;
}

fn createDevice(
    dis: InstanceDispatch,
    phy_dev: vk.PhysicalDevice,
    gfx: u32,
) !vk.Device {
    const prio = [_]f32{1.0};
    const queue_create_infos = .{
        .{
            .queue_family_index = gfx,
            .queue_count = 1,
            .p_queue_priorities = &prio,
        },
    };

    const device = dis.createDevice(
        phy_dev,
        &vk.DeviceCreateInfo{
            .queue_create_info_count = queue_create_infos.len,
            .p_queue_create_infos = &queue_create_infos,
        },
        null,
    );

    return device;
}
