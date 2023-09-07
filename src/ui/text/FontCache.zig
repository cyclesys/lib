const std = @import("std");
const ft = @import("freetype");
const hb = @import("harfbuzz");
const kf = @import("known_folders");

const Self = @This();

allocator: std.mem.Allocator,
lib: ft.Library,
face: ft.Face,
font: hb.Font,

pub const Key = union(enum) {
    index: u32,
    size: f16,
};

pub fn init(allocator: std.mem.Allocator) !Self {
    const fonts_path = if (try kf.getPath(allocator, .fonts)) |path| path else {
        return error.NoFontsFolder;
    };
    defer allocator.free(fonts_path);

    const face_path = try std.fs.path.joinZ(allocator, &.{ fonts_path, "segoeui.ttf" });
    defer allocator.free(face_path);

    const lib = try ft.Library.init();
    const face = try lib.createFace(@ptrCast(face_path), 0);
    const font = hb.Font.init(hb.Face.fromFreetypeFace(face));

    return Self{
        .allocator = allocator,
        .lib = lib,
        .face = face,
        .font = font,
    };
}

pub fn deinit(self: Self) void {
    self.font.deinit();
    self.face.deinit();
    self.lib.deinit();
}
