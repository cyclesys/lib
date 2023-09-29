const std = @import("std");
const vk = @import("vulkan");
const tree = @import("../tree.zig");
const fns = @import("fns.zig");
const FontCache = @import("../text/FontCache.zig");
const GlyphCache = @import("../text/GlyphCache.zig");
const Context = @import("Context.zig");
const Swapchain = @import("Swapchain.zig");
const TreeData = @import("TreeData.zig");

allocator: std.mem.Allocator,
fonts: FontCache,
glyphs: GlyphCache,
context: Context,

const Self = @This();

pub fn init(
    allocator: std.mem.Allocator,
    app_name: ?[:0]const u8,
    app_version: ?Context.AppVersion,
    dev_uuid: Context.DeviceId,
) !Self {
    return Self{
        .allocator = allocator,
        .fonts = try FontCache.init(allocator),
        .glyphs = try GlyphCache.init(allocator),
        .context = try Context.init(allocator, app_name, app_version, dev_uuid),
    };
}

pub fn render(self: *Self, render_tree: anytype, swapchain: *Swapchain) !void {
    const data = try TreeData.create(self.allocator, &self.fonts, &self.glyphs, render_tree);
    const target = try swapchain.target();
    _ = data;
    _ = target;
}
