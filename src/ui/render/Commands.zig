const vk = @import("vulkan");
const Context = @import("Context.zig");

pool: vk.CommandPool,
buffer: vk.CommandBuffer,
queue: vk.Queue,
fence: vk.Fence,

const Self = @This();

pub fn init(context: *const Context) !Self {
    const pool = try context.device_fns.createCommandPool(
        context.device,
        &vk.CommandPoolCreateInfo{
            .queue_family_index = context.queue_family_index,
        },
        null,
    );

    var buffer: vk.CommandBuffer = undefined;
    try context.device_fns.allocateCommandBuffers(
        context.device,
        &vk.CommandBufferAllocateInfo{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = 1,
        },
        &buffer,
    );

    const queue = context.device_fns.getDeviceQueue(context.device, context.queue_family_index, 0);

    const fence = try context.device_fns.createFence(
        context.device,
        vk.FenceCreateInfo{
            .flags = vk.FenceCreateFlags{
                .signaled_bit = true,
            },
        },
        null,
    );

    return Self{
        .pool = pool,
        .buffer = buffer,
        .queue = queue,
        .fence = fence,
    };
}

pub fn deinit(self: *const Self, context: *const Context) void {
    context.device_fns.destroyFence(context.device, self.fence, null);
    context.device_fns.freeCommandBuffers(context.device, self.pool, 1, &self.buffer);
    context.device_fns.destroyCommandPool(context.device, self.pool, null);
}

pub fn begin(self: *const Self, context: *const Context) !void {
    try context.device_fns.beginCommandBuffer(
        self.buffer,
        &vk.CommandBufferBeginInfo{
            .flags = vk.CommandBufferUsageFlags{
                .one_time_submit_bit = true,
            },
        },
    );
}

pub fn submit(self: *const Self, context: *const Context) !void {
    try context.device_fns.endCommandBuffer(self.buffer);
    try context.device_fns.queueSubmit(
        self.queue,
        1,
        &vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = &self.buffer,
        },
        self.fence,
    );
    if (try context.device_fns.waitForFences(
        context.device,
        1,
        &self.fence,
        vk.TRUE,
        100000000000,
    ) != .success) {
        return error.CommandSubmitFailed;
    }
}

pub fn copyBuffer(
    self: *const Self,
    context: *const Context,
    src: vk.Buffer,
    dst: vk.Buffer,
    region: vk.BufferCopy,
) void {
    context.device_fns.cmdCopyBuffer(
        self.buffer,
        src,
        dst,
        1,
        &region,
    );
}

pub fn pipelineImageBarrier(
    self: *const Self,
    context: *const Context,
    src_stage_mask: vk.PipelineStageFlags,
    dst_stage_mask: vk.PipelineStageFlags,
    dependency_flags: vk.DependencyFlags,
    image_memory_barrier: vk.ImageMemoryBarrier,
) void {
    context.device_fns.cmdPipelineBarrier(
        self.buffer,
        src_stage_mask,
        dst_stage_mask,
        dependency_flags,
        0,
        null,
        0,
        null,
        1,
        &image_memory_barrier,
    );
}

pub fn copyBufferToImage(
    self: *const Self,
    context: *const Context,
    src_buffer: vk.Buffer,
    dst_image: vk.Image,
    dst_image_layout: vk.ImageLayout,
    region: vk.BufferImageCopy,
) void {
    context.device_fns.cmdCopyBufferToImage(
        self.buffer,
        src_buffer,
        dst_image,
        dst_image_layout,
        1,
        &region,
    );
}
