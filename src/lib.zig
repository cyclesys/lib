pub const def = struct {
    pub usingnamespace @import("def/define.zig");
    pub usingnamespace @import("def/definition.zig");
    pub usingnamespace @import("def/ids.zig");
};

pub const chan = struct {
    pub usingnamespace @import("chan/SharedMem.zig");
    pub usingnamespace @import("chan/channel.zig");
    pub usingnamespace @import("chan/serde.zig");
};

pub const main = @import("init.zig");
pub const InitConfig = main.InitConfig;
pub const init = main.init;

test {
    _ = @import("def/definition.zig");
    _ = @import("chan/channel.zig");
    _ = @import("chan/serde.zig");
}
