const std = @import("std");
const tree = @import("../tree.zig");
const FontCache = @import("../text/FontCache.zig");
const GlyphCache = @import("../text/GlyphCache.zig");
const nodes = @import("nodes.zig");
const Pipeline = @import("Pipeline.zig");

allocator: std.mem.Allocator,
vertices: []const Pipeline.Vertex,
indices: []const u32,

const Self = @This();

const State = struct {
    vertices: std.ArrayList(Pipeline.Vertex),
    indices: std.ArrayList(u32),
    fonts: *FontCache,
    glyphs: *GlyphCache,
};

pub fn create(
    allocator: std.mem.Allocator,
    fonts: *FontCache,
    glyphs: *GlyphCache,
    render_tree: anytype,
) !Self {
    var state = State{
        .vertices = std.ArrayList(Pipeline.Vertex).init(allocator),
        .indices = std.ArrayList(u32).init(allocator),
        .fonts = fonts,
        .glyphs = glyphs,
    };
    try addRenderTree(&state, render_tree);
    return Self{
        .allocator = allocator,
        .vertices = try state.vertices.toOwnedSlice(),
        .indices = try state.indices.toOwnedSlice(),
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.indices);
    self.allocator.free(self.vertices);
}

fn addRenderTree(state: *State, render_tree: anytype) !void {
    const RenderTree = @TypeOf(render_tree);
    if (std.meta.trait.isTuple(RenderTree)) {
        try addTuple(state, render_tree);
    } else {
        try addNode(state, render_tree);
    }
}

fn addTuple(state: *State, tuple: anytype) !void {
    inline for (tuple) |node| {
        try addNode(state, node);
    }
}

fn addNode(state: *State, node: anytype) !void {
    const Node = @TypeOf(node);
    switch (Node.id) {
        .Rect => {
            try addQuad(state, node.offset, node.info.color, [_]u32{ 0, 0, 0 });
            if (Node.Child != void) {
                try addRenderTree(state, node.child);
            }
        },
        .Text => {
            try addText(node.offset, node.size, node.info);
        },
        else => @compileError("invalid render node"),
    }
}

fn addText(state: *State, offset: tree.Offset, text: nodes.RenderText) !void {
    for (text.glyphs) |glyph| {
        const quad_offset = offset.plus(tree.Offset{
            .x = glyph.x,
            .y = glyph.y,
        });
        const quad_x: u16 = @intCast(quad_offset.x);
        const quad_y: u16 = @intCast(quad_offset.y);

        const atlas_region = try state.glyphs.get(glyph.key, state.fonts);
        const atlas_x: u16 = @intCast(atlas_region.x);
        const atlas_y: u16 = @intCast(atlas_region.y);

        const glyph_x: u32 = (quad_x << 16) & atlas_x;
        const glyph_y: u32 = (quad_y << 16) & atlas_y;

        try addQuad(
            state,
            quad_offset,
            tree.Size{
                .width = atlas_region.width,
                .height = atlas_region.height,
            },
            text.color,
            [_]u32{
                1,
                glyph_x,
                glyph_y,
            },
        );
    }
}

fn addQuad(
    state: *State,
    offset: tree.Offset,
    size: tree.Size,
    color: nodes.Color,
    glyph: [2]u32,
) !void {
    const top_left_index = state.vertices.items.len;
    const top_right_index = top_left_index + 1;
    const bottom_right_index = top_right_index + 1;
    const bottom_left_index = bottom_right_index + 1;

    try state.vertices.ensureUnusedCapacity(4);
    try state.vertices.appendSliceAssumeCapacity(&.{
        // top-left
        Pipeline.Vertex{
            .pos = [_]f32{ offset.x, offset.y },
            .color = color,
            .glyph = glyph,
        },
        // top-right
        Pipeline.Vertex{
            .pos = [_]f32{ offset.x + size.width, offset.y },
            .color = color,
            .glyph = glyph,
        },
        // bottom-right
        Pipeline.Vertex{
            .pos = [_]f32{ offset.x + size.width, offset.y + size.height },
            .color = color,
            .glyph = glyph,
        },
        // bottom-left
        Pipeline.Vertex{
            .pos = [_]f32{ offset.x, offset.y + size.height },
            .color = color,
            .glyph = glyph,
        },
    });

    try state.indices.ensureUnusedCapacity(6);
    try state.indices.appendSliceAssumeCapacity(&.{
        top_left_index,
        top_right_index,
        bottom_left_index,

        bottom_right_index,
        bottom_left_index,
        top_right_index,
    });
}
