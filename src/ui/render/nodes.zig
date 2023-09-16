const std = @import("std");
const tree = @import("../tree.zig");
const LayoutBuffer = @import("../text/LayoutBuffer.zig");
const FontCache = @import("../text/FontCache.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    fonts: *FontCache,
};

// TODO: move this elsewhere?
pub const Color = [4]f32;

pub fn rect(config: anytype) Rect(tree.Child(@TypeOf(config))) {
    const RectNode = Rect(tree.Child(@TypeOf(config)));
    return tree.initNode(RectNode, config);
}

pub fn Rect(comptime Child: type) type {
    return tree.RenderNode(.Rect, Child, struct {
        color: Color,
    });
}

pub fn text(config: anytype) Text {
    return tree.initNode(Text, config);
}

pub const Text = tree.RenderNode(.Text, void, struct {
    text: []const u32,
    font_size: f16,
    color: Color,

    pub const State = struct {
        font_size: f16,
        buffer: LayoutBuffer,

        pub fn init(self: *State, opts: Opts, context: *Context) !void {
            var buffer = LayoutBuffer.init(context.allocator, context.fonts);
            try buffer.setText(opts.text);
            self.* = State{
                .font_size = opts.font_size,
                .buffer = buffer,
            };
        }

        pub fn deinit(self: *State) void {
            if (self.layer) |layer| {
                layer.deinit();
                self.layer = null;
            }
            self.buffer.deinit();
        }

        pub fn update(self: *State, opts: Opts) !void {
            if (!self.buffer.hasText(opts.text)) {
                self.buffer.setText(opts.text);
            }
            self.font_size = opts.font_size;
        }
    };
    const Opts = @This();

    pub fn layout(state: *State, opts: Opts, constraints: tree.Constraints, out: *RenderText) !tree.Size {
        if (constraints.width == null) {
            return error.TextWidthUnconstrained;
        }

        const size = try state.buffer.layout(state.size, constraints.width.?, constraints.height);
        out.* = RenderText{
            .color = opts.color,
            .glyphs = state.buffer.layoutGlyphs(),
        };
        return size;
    }
});

pub const RenderText = struct {
    color: Color,
    glyphs: []const LayoutBuffer.LayoutGlyph,
};
