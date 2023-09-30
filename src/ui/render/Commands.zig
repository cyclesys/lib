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

pub fn beginRenderPass(
    self: *const Self,
    context: *const Context,
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,
    width: u32,
    height: u32,
) void {
    context.device_fns.cmdBeginRenderPass(
        self.buffer,
        &vk.RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .render_area = vk.Rect2D{
                .offset = vk.Offset2D{
                    .x = 0,
                    .y = 0,
                },
                .extent = vk.Extent2D{
                    .width = width,
                    .height = height,
                },
            },
            .clear_value_count = 1,
            .p_clear_values = &vk.ClearValue{
                .color = vk.ClearColorValue{
                    .float_32 = [_]f32{ 0.0, 0.0, 0.0, 0.0 },
                },
            },
        },
        .@"inline",
    );
}

pub fn endRenderPass(self: *const Self, context: *const Context) void {
    context.device_fns.cmdEndRenderPass(self.buffer);
}

pub fn setViewport(self: *const Self, context: *const Context, width: f32, height: f32) void {
    context.device_fns.cmdSetViewport(
        self.buffer,
        0,
        1,
        &vk.Viewport{
            .x = 0.0,
            .y = 0.0,
            .width = width,
            .height = height,
            .min_depth = 1.0,
            .max_depth = 1.0,
        },
    );
}

pub fn setScissor(self: *const Self, context: *const Context, width: u32, height: u32) void {
    context.device_fns.cmdSetScissor(
        self.buffer,
        0,
        1,
        &vk.Rect2D{
            .offset = vk.Offset2D{
                .x = 0,
                .y = 0,
            },
            .extent = vk.Extent2D{
                .width = width,
                .height = height,
            },
        },
    );
}

pub fn bindDescriptorSet(
    self: *const Self,
    context: *const Context,
    layout: vk.PipelineLayout,
    descriptor_set: vk.DescriptorSet,
) void {
    context.device_fns.cmdBindDescriptorSets(
        self.buffer,
        .graphics,
        layout,
        0,
        1,
        &descriptor_set,
        0,
        null,
    );
}

pub fn bindGraphicsPipeline(self: *const Self, context: *const Context, pipeline: vk.Pipeline) void {
    context.device_fns.cmdBindPipeline(
        self.buffer,
        .graphics,
        pipeline,
    );
}

pub fn bindVertexBuffer(self: *const Self, context: *const Context, buffer: vk.Buffer) void {
    const offset: vk.DeviceSize = 0;
    context.device_fns.cmdBindVertexBuffers(
        self.buffer,
        0,
        1,
        &buffer,
        &offset,
    );
}

pub fn bindIndexBuffer(self: *const Self, context: *const Context, buffer: vk.Buffer) void {
    context.device_fns.cmdBindIndexBuffer(
        self.buffer,
        buffer,
        0,
        .uint32,
    );
}

pub fn drawIndexed(self: *const Self, context: *const Context, index_count: u32) void {
    context.device_fns.cmdDrawIndexed(
        self.buffer,
        index_count,
        1,
        0,
        0,
        0,
    );
}
