const std = @import("std");
const vk = @import("vulkan");
const tree = @import("../tree.zig");
const fns = @import("fns.zig");
const FontCache = @import("../text/FontCache.zig");
const GlyphCache = @import("../text/GlyphCache.zig");
const Buffer = @import("Buffer.zig");
const Commands = @import("Commands.zig");
const Context = @import("Context.zig");
const Pipeline = @import("Pipeline.zig");
const Swapchain = @import("Swapchain.zig");
const TreeData = @import("TreeData.zig");
const Uniforms = @import("Uniforms.zig");

allocator: std.mem.Allocator,
first_render: bool,
fonts: FontCache,
glyphs: GlyphCache,
context: Context,
commands: Commands,
uniforms: Uniforms,
pipeline: Pipeline,

const Self = @This();

pub fn init(
    allocator: std.mem.Allocator,
    app_name: ?[:0]const u8,
    app_version: ?Context.AppVersion,
    dev_uuid: Context.DeviceId,
) !Self {
    const fonts = try FontCache.init(allocator);
    const glyphs = try GlyphCache.init(allocator);
    const context = try Context.init(allocator, app_name, app_version, dev_uuid);
    const commands = try Commands.init(&context);
    const uniforms = try Uniforms.init(&context, glyphs.atlas.size);
    const pipeline = try Pipeline.init(&context);
    return Self{
        .allocator = allocator,
        .first_render = true,
        .fonts = fonts,
        .glyphs = glyphs,
        .context = context,
        .commands = commands,
        .uniforms = uniforms,
        .pipeline = pipeline,
    };
}

pub fn render(self: *Self, render_tree: anytype, width: u32, height: u32, swapchain: *Swapchain) !void {
    const data = try TreeData.create(self.allocator, &self.fonts, &self.glyphs, render_tree);

    if (self.first_render) {
        try self.uniforms.setGamma(&self.context, &self.commands, 1.0);
        if (self.glyphs.atlas.resized) {
            try self.uniforms.resizeAtlas(&self.context, self.glyphs.atlas.size);
        }
        try self.uniforms.setAtlas(&self.context, &self.commands, self.glyphs.atlas.data);
        self.glyphs.atlas.modified = false;
        self.glyphs.atlas.resized = false;

        try self.pipeline.setGamma(&self.context, self.uniforms.gamma.buffer);
        try self.pipeline.setAtlas(&self.context, self.uniforms.atlas.sampler, self.uniforms.atlas.view);

        self.first_render = false;
    } else if (self.glyphs.atlas.resized) {
        try self.uniforms.resizeAtlas(&self.context, self.glyphs.atlas.size);
        self.glyphs.atlas.resized = false;

        try self.pipeline.setAtlas(&self.context, self.uniforms.atlas.sampler, self.uniforms.atlas.view);
    } else if (self.glyphs.atlas.modified) {
        try self.uniforms.setAtlas(&self.context, &self.commands, self.glyphs.atlas.data);
        self.glyphs.atlas.modified = false;
    }

    const vertex_buffer = try Buffer.init(
        &self.context,
        @intCast(data.vertices.len * @sizeOf(Pipeline.Vertex)),
        vk.BufferUsageFlags{ .vertex_buffer_bit = true },
        true,
    );
    defer vertex_buffer.deinit(&self.context);

    try vertex_buffer.copy(&self.context, @ptrCast(data.vertices));
    try vertex_buffer.bind(&self.context);

    const index_buffer = try Buffer.init(
        &self.context,
        @intCast(data.indices.len * @sizeOf(u32)),
        vk.BufferUsageFlags{ .index_buffer_bit = true },
        true,
    );
    defer index_buffer.deinit(&self.context);

    try index_buffer.copy(&self.context, @ptrCast(data.indices));
    try index_buffer.bind(&self.context);

    const target = try swapchain.target();

    try self.commands.begin(&self.context);
    self.commands.beginRenderPass(&self.context, self.pipeline.render_pass, target.framebuffer, width, height);
    self.commands.setViewport(&self.context, @floatFromInt(width), @floatFromInt(height));
    self.commands.setScissor(&self.context, width, height);
    self.commands.bindDescriptorSet(&self.context, self.pipeline.pipeline_layout, self.pipeline.descriptor_set);
    self.commands.bindGraphicsPipeline(&self.context, self.pipeline.pipeline);
    self.commands.bindVertexBuffer(&self.context, vertex_buffer.buffer);
    self.commands.bindIndexBuffer(&self.context, index_buffer.buffer);
    self.commands.drawIndexed(&self.context, @intCast(data.indices.len));
    self.commands.endRenderPass(&self.context);
    try self.commands.submit(&self.context);

    try swapchain.swap();
}
