const def = @import("../lib.zig").def;

const Scheme = def.Scheme("Cycle", .{
    def.Object("Color", .{struct {
        red: f32,
        green: f32,
        blue: f32,
        alpha: f32,
    }}),
});

pub const Color = Scheme.ref("Color");
