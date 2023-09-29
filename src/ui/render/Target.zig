const vk = @import("vulkan");
const win = @import("../../windows.zig");
const Context = @import("Context.zig");
const Pipeline = @import("Pipeline.zig");

image: vk.Image,
view: vk.ImageView,
memory: vk.DeviceMemory,
framebuffer: vk.Framebuffer,

const Self = @This();

pub fn init(
    context: *const Context,
    pipeline: *const Pipeline,
    width: u32,
    height: u32,
) !Self {
    const image = try context.device_fns.createImage(
        context.device,
        &vk.ImageCreateInfo{
            .image_type = .@"2d",
            .format = .r32g32b32a32_sfloat,
            .extent = vk.Extent3D{
                .width = width,
                .height = height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .@"1_bit",
            .tiling = .optimal,
            .usage = vk.ImageUsageFlags{
                .sampled_bit = true,
                .input_attachment_bit = true,
            },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 1,
            .p_queue_family_indices = &context.queue_family_index,
            .initial_layout = .undefined,
        },
        null,
    );

    const view = try context.device_fns.createImageView(
        context.device,
        &vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = .r32g32b32a32_sfloat,
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

    const reqs = context.device_fns.getImageMemoryRequirements(context.device, image);

    const memory = try context.device_fns.allocateMemory(
        context.device,
        &vk.MemoryAllocateInfo{
            .p_next = &vk.ExportMemoryAllocateInfo{
                .handle_types = vk.ExternalMemoryHandleTypeFlags{ .opaque_win32_bit = true },
            },
            .allocation_size = reqs.size,
            .memory_type_index = context.device_local_memory_index,
        },
        null,
    );

    try context.device_fns.bindImageMemory(context.device, image, memory, 0);

    const framebuffer = try context.device_fns.createFramebuffer(
        context.device,
        &vk.FramebufferCreateInfo{
            .render_pass = pipeline.render_pass,
            .attachment_count = 1,
            .p_attachments = &view,
            .width = width,
            .height = height,
            .layers = 1,
        },
        null,
    );

    return Self{
        .memory = memory,
        .image = image,
        .view = view,
        .framebuffer = framebuffer,
    };
}

pub fn memHandle(
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
