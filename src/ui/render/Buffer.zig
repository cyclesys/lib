const vk = @import("vulkan");
const Context = @import("Context.zig");

buffer: vk.Buffer,
memory_size: vk.DeviceSize,
memory: vk.DeviceMemory,

const Self = @This();

pub fn init(context: *const Context, size: vk.DeviceSize, usage: vk.BufferUsageFlags, host_visible: bool) !Self {
    const buffer = try context.device_fns.createBuffer(
        context.device,
        &vk.BufferCreateInfo{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        },
        null,
    );

    const mem_reqs = context.device_fns.getBufferMemoryRequirements(context.device, buffer);

    const memory = try context.device_fns.allocateMemory(
        context.device,
        &vk.MemoryAllocateInfo{
            .allocation_size = mem_reqs.size,
            .memory_type_index = if (host_visible)
                context.host_visible_memory_index
            else
                context.device_local_memory_index,
        },
        null,
    );

    return Self{
        .buffer = buffer,
        .memory_size = mem_reqs.size,
        .memory = memory,
    };
}

pub fn deinit(self: Self, context: *const Context) void {
    context.device_fns.destroyBuffer(context.device, self.buffer, null);
    context.device_fns.freeMemory(context.device, self.memory, null);
}

pub fn copy(self: *const Self, context: *const Context, bytes: []const u8) !void {
    const data = try context.device_fns.mapMemory(
        context.device,
        self.memory,
        0,
        self.memory_size,
        vk.MemoryMapFlags{},
    ).?;
    @memcpy(data[0..bytes.len], bytes);
    context.device_fns.unmapMemory(context.device, self.memory);
}

pub fn bind(self: *const Self, context: *const Context) !void {
    try context.device_fns.bindBufferMemory(
        context.device,
        self.buffer,
        self.memory,
        0,
    );
}
