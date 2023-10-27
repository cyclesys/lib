pub const def = struct {
    pub const ObjectScheme = @import("def/ObjectScheme.zig");
    pub usingnamespace @import("def/define.zig");
    pub usingnamespace @import("def/ids.zig");
    pub usingnamespace @import("def/type.zig");
};

pub const chan = struct {
    pub usingnamespace @import("chan/SharedMem.zig");
    pub usingnamespace @import("chan/channel.zig");
    pub usingnamespace @import("chan/serde.zig");
};

pub const main = @import("main.zig");
pub const InitConfig = main.InitConfig;
pub const init = main.init;

test {
    _ = @import("def/ObjectScheme.zig");
    _ = @import("def/Type.zig");
    _ = @import("chan/channel.zig");
    _ = @import("chan/serde.zig");
    _ = @import("obj/serde.zig");
}
