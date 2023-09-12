const std = @import("std");
const ft = @import("freetype");
const win = @import("../../windows.zig");
const FontCache = @import("FontCache.zig");
const GlyphAtlas = @import("GlyphAtlas.zig");

allocator: std.mem.Allocator,
regions: std.AutoHashMap(Key, GlyphAtlas.Region),
atlas: GlyphAtlas,

pub const Key = struct {
    // TODO: update this to be a glyph index AND font id once multiple font support
    // is added to FontCache.
    glyph_index: u32,
    font_size: u16,
};

const Self = @This();

pub fn init(allocator: std.mem.Allocator) !Self {
    return Self{
        .allocator = allocator,
        .regions = std.AutoHashMap(Key, GlyphAtlas.Region).init(allocator),
        .atlas = try GlyphAtlas.init(allocator, 128, .greyscale),
    };
}

pub fn get(self: *Self, key: Key, fonts: *FontCache) !GlyphAtlas.Region {
    if (self.regions.get(key)) |r| {
        return r;
    }

    const dpi = win.GetDpiForSystem();

    try fonts.face.setCharSize(key.font_size * 64, 0, dpi, 0);
    try fonts.face.loadGlyph(key.glyph_index, .{});

    const slot = fonts.face.glyph();
    try slot.render(.normal);

    const bitmap = slot.bitmap();
    const width = bitmap.width();
    const height = bitmap.rows();

    var pitch = bitmap.pitch();
    const negative_pitch = pitch < 0;
    pitch = std.math.absInt(pitch);

    const buffer = bitmap.buffer().?;

    const data = try self.allocator.alloc(u8, width * height);
    defer self.allocator.free(data);

    for (0..height) |i| {
        @memcpy(
            data[i * width ..][0..width],
            if (negative_pitch)
                buffer[(height - i - 1) * pitch ..][0..width]
            else
                buffer[i * pitch ..][0..width],
        );
    }

    const region = try self.atlas.put(width, height, data);
    try self.regions.put(key, region);
    return region;
}
