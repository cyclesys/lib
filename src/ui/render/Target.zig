const vk = @import("vulkan");
const win = @import("../../windows.zig");
const fns = @import("fns.zig");

memory: vk.DeviceMemory,
image: vk.Image,
image_view: vk.ImageView,

const Self = @This();

pub fn create(
    device_fns: anytype,
    device: vk.Device,
    memory_type_index: u32,
    format: vk.Format,
    queue_family_index: u32,
    width: u32,
    height: u32,
) !Self {
    const iv = try createImageAndView(
        device_fns,
        device,
        format,
        queue_family_index,
        width,
        height,
        vk.ImageUsageFlags{
            .sampled_bit = true,
            .input_attachment_bit = true,
        },
    );

    const memory = try device_fns.allocateMemory(
        device,
        &vk.MemoryAllocateInfo{
            .p_next = &vk.ExportMemoryAllocateInfo{
                .handle_types = vk.ExternalMemoryHandleTypeFlags{ .opaque_win32_bit = true },
            },
            .allocation_size = iv.reqs.size,
            .memory_type_index = memory_type_index,
        },
        null,
    );

    return Self{
        .memory = memory,
        .image = iv.image,
        .view = iv.view,
    };
}

pub fn exportMemory(
    self: *Self,
    device_fns: anytype,
    dev: vk.Device,
) !win.HANDLE {
    var handle: win.HANDLE = undefined;
    try device_fns.getMemoryWin32HandleKHR(
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
    device_fns: fns.DeviceFns,
    device: vk.Device,
    memory_type_index: u32,
    format: vk.Format,
    queue_family_index: u32,
    width: u32,
    height: u32,
    handle: win.HANDLE,
) !Self {
    const iv = try createImageAndView(
        device_fns,
        device,
        format,
        queue_family_index,
        width,
        height,
        vk.ImageUsageFlags{ .color_attachment_bit = true },
    );

    const memory = try device_fns.allocateMemory(
        device,
        &vk.MemoryAllocateInfo{
            .p_next = &vk.ImportMemoryWin32HandleInfoKHR{
                .handle_type = vk.ExternalMemoryHandleTypeFlags{ .opaque_win32_bit = true },
                .handle = handle,
                .name = null,
            },
            .allocation_size = iv.reqs.size,
            .memory_type_index = memory_type_index,
        },
        null,
    );

    return Self{
        .memory = memory,
        .image = iv.image,
        .view = iv.view,
    };
}

fn createImageAndView(
    device_fns: anytype,
    device: vk.Device,
    format: vk.Format,
    queue_family_index: u32,
    width: u32,
    height: u32,
    usage: vk.ImageUsageFlags,
) !struct {
    image: vk.Image,
    view: vk.ImageView,
    reqs: vk.MemoryRequirements,
} {
    const image = try device_fns.createImage(
        device,
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
            .p_queue_family_indices = &queue_family_index,
            .initial_layout = .undefined,
        },
        null,
    );

    const view = try device_fns.createImageView(
        device,
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

    const reqs = device_fns.getImageMemoryRequirements(device, image);

    return .{
        image,
        view,
        reqs,
    };
}
