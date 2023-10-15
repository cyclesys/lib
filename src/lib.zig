pub const def = struct {
    pub usingnamespace @import("define.zig");
    pub usingnamespace @import("definition.zig");
};

pub const chan = struct {
    pub usingnamespace @import("channel.zig");
    pub usingnamespace @import("channel/serde.zig");
};

pub const init = @import("init.zig");
pub const object = @import("object.zig");
pub const ui = @import("ui.zig");
pub const SharedMem = @import("SharedMem.zig");

pub const InitChannel = init.InitChannel;

pub const ObjectChannel = object.channel.ObjectChannel;
pub const ObjectIndex = object.index.ObjectIndex;
pub const ObjectView = object.read.ObjectView;
pub const ObjectValue = object.write.ObjectValue;
pub const ObjectMut = object.write.ObjectMut;

test {
    _ = @import("channel.zig");
    _ = @import("definition.zig");
    _ = @import("object.zig");
    _ = @import("serde.zig");
    _ = @import("ui.zig");
}
