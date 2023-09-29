const vk = @import("vulkan");
const Buffer = @import("Buffer.zig");
const Commands = @import("Commands.zig");
const Context = @import("Context.zig");

gamma: Buffer,
atlas: Atlas,

pub const Atlas = struct {
    size: u32,
    initialized: bool,
    image: vk.Image,
    view: vk.ImageView,
    memory: vk.DeviceMemory,
};
const Self = @This();

pub fn init(context: *const Context, atlas_size: u32) !Self {
    return Self{
        .gamma = try Buffer.init(
            context,
            @sizeOf(f32),
            vk.BufferUsageFlags{
                .uniform_buffer_bit = true,
                .transfer_dst_bit = true,
            },
            false,
        ),
        .atlas = try initAtlas(context, atlas_size),
    };
}

pub fn deinit(self: *const Self, context: *const Context) void {
    deinitAtlas(self.atlas, context);
    self.gamma.deinit(context);
}

pub fn setGamma(self: *const Self, context: *const Context, commands: *const Commands, gamma: f32) !void {
    const staging = try Buffer.init(
        context,
        @sizeOf(f32),
        vk.BufferUsageFlags{ .transfer_src_bit = true },
        true,
    );
    defer staging.deinit();

    var bytes: []const u8 = undefined;
    bytes.ptr = @ptrCast(&gamma);
    bytes.len = @sizeOf(f32);

    try staging.copy(context, bytes);
    try staging.bind();

    try commands.begin(context);
    commands.copyBuffer(
        context,
        staging.buffer,
        self.gamma.buffer,
        vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = 0,
            .size = @sizeOf(f32),
        },
    );
    try commands.submit(context);
}

pub fn resizeAtlas(self: *Self, context: *const Context, size: u32) !void {
    deinitAtlas(self.atlas);
    self.atlas = try initAtlas(context, size);
}

pub fn setAtlas(self: *const Self, context: *const Context, commands: *const Commands, data: []const u8) !void {
    const staging = try Buffer.init(
        context,
        data.len,
        vk.BufferUsageFlags{ .transfer_src_bit = true },
        true,
    );
    defer staging.deinit();

    try staging.copy(context, data);
    try staging.bind();

    try commands.begin(context);
    commands.pipelineImageBarrier(
        context,
        if (self.atlas.initialized)
            vk.PipelineStageFlags{ .fragment_shader_bit = true }
        else
            vk.PipelineStageFlags{ .host_bit = true },
        vk.PipelineStageFlags{ .transfer_bit = true },
        vk.DependencyFlags{},
        vk.ImageMemoryBarrier{
            .src_access_mask = if (self.atlas.initialized)
                vk.AccessFlags{ .shader_read_bit = true }
            else
                vk.AccessFlags{ .undefined = true },
            .dst_access_mask = vk.AccessFlags{ .transfer_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = 0,
            .dst_queue_family_index = 0,
            .image = self.atlas.image,
            .subresource_range = vk.ImageSubresourceRange{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        },
    );
    commands.copyBufferToImage(
        context,
        staging.buffer,
        self.atlas.image,
        .transfer_dst_optimal,
        vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = self.atlas.size,
            .buffer_image_height = self.atlas.size,
            .image_subresource = vk.ImageSubresourceLayers{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = vk.Offset3D{
                .x = 0,
                .y = 0,
                .z = 0,
            },
            .image_extent = vk.Extent3D{
                .width = self.atlas.size,
                .height = self.atlas.size,
                .depth = 1,
            },
        },
    );
    commands.pipelineImageBarrier(
        context,
        vk.PipelineStageFlags{ .transfer_bit = true },
        vk.PipelineStageFlags{ .fragment_shader_bit = true },
        vk.DependencyFlags{},
        vk.ImageMemoryBarrier{
            .src_access_mask = vk.AccessFlags{ .transfer_write_bit = true },
            .dst_access_mask = vk.AccessFlags{ .shader_read_bit = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = .read_only_optimal,
            .src_queue_family_index = 0,
            .dst_queue_family_index = 0,
            .image = self.atlas.image,
            .subresource_range = vk.ImageSubresourceRange{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        },
    );
    try commands.submit(context);
}

fn initAtlas(context: *const Context, size: u32) !Atlas {
    const image = try context.device_fns.createImage(
        context.device,
        &vk.ImageCreateInfo{
            .image_type = .@"2d",
            .format = .r8_uint,
            .extent = vk.Extent3D{
                .width = size,
                .height = size,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .@"1_bit",
            .tiling = .optimal,
            .usage = vk.ImageUsageFlags{
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 1,
            .p_queue_family_indices = &context.queue_family_index,
            .initial_layout = .undefined,
        },
    );
    const view = try context.device_fns.createImageView(
        context.device,
        &vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = .r8_uint,
            .components = vk.ComponentMapping{
                .r = .identity,
                .g = .zero,
                .b = .zero,
                .a = .zero,
            },
            .subresource_range = vk.ImageSubresourceRange{
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
    const memory = try context.device.fns.allocateMemory(
        context.device,
        &vk.MemoryAllocateInfo{
            .allocation_size = reqs.size,
            .memory_type_index = context.device_local_memory_index,
        },
        null,
    );
    try context.device_fns.bindImageMemory(context.device, image, memory, 0);
    return Atlas{
        .size = size,
        .image = image,
        .view = view,
        .memory = memory,
    };
}

fn deinitAtlas(atlas: Atlas, context: *const Context) void {
    context.device_fns.destroyImageView(context.device, atlas.view, null);
    context.device_fns.destroyImage(context.device, atlas.image, null);
    context.device_fns.freeMemory(context.device, atlas.memory, null);
}
