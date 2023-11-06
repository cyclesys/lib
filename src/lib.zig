pub const chan = struct {
    pub usingnamespace @import("chan/SharedMem.zig");
    pub usingnamespace @import("chan/channel.zig");
    pub usingnamespace @import("chan/serde.zig");
};

pub const def = struct {
    pub const ObjectScheme = @import("def/ObjectScheme.zig");
    pub usingnamespace @import("def/define.zig");
    pub usingnamespace @import("def/ids.zig");
    pub usingnamespace @import("def/type.zig");
};

const init_mod = @import("init.zig");
pub const SystemMessage = init_mod.SystemMessage;
pub const PluginMessage = init_mod.PluginMessage;
pub const InitConfig = init_mod.InitConfig;
pub const init = init_mod.init;

pub const obj = struct {
    pub usingnamespace @import("obj/index.zig");

    const serde = @import("obj/serde.zig");
    pub const UpdateObject = serde.UpdateObject;

    pub usingnamespace @import("obj/write.zig");
};

pub const ui = struct {
    pub const render = struct {
        pub const vulkanLoader = @import("ui/render/Context.zig").vulkanLoader;
    };
};

test {
    _ = @import("def/ObjectScheme.zig");
    _ = @import("def/Type.zig");
    _ = @import("chan/channel.zig");
    _ = @import("chan/serde.zig");
    _ = @import("obj/write.zig");
    _ = @import("ui/text/bidi.zig");
    _ = @import("ui/text/GlyphAtlas.zig");
    _ = @import("ui/text/GraphemeBreak.zig");
    _ = @import("ui/text/LineBreak.zig");
    _ = @import("ui/text/WordBreak.zig");
}
