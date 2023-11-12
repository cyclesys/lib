const std = @import("std");
const win = @import("windows.zig");

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

pub const obj = struct {
    pub usingnamespace @import("obj/index.zig");
    pub usingnamespace @import("obj/serde.zig");
    pub usingnamespace @import("obj/store.zig");
    pub usingnamespace @import("obj/write.zig");
};

pub const ui = struct {
    pub const render = struct {
        pub const vulkanLoader = @import("ui/render/Context.zig").vulkanLoader;
    };
};

pub const SystemMessage = union(enum) {
    AddObject: struct {
        id: u128,
        bytes: []const u8,
    },
    UpdateObject: struct {
        id: u128,
        bytes: []const u8,
    },
    RemoveObject: struct {
        id: u128,
    },
};

pub const PluginMessage = union(enum) {
    SetVersion: struct {
        major: u16,
        minor: u16,
    },
    SetIndex: []const def.ObjectScheme,
    Finalize: void,
};

pub fn init(allocator: std.mem.Allocator, cfg: struct {
    index: []const def.ObjectScheme,
}) !struct {
    chan.Reader(SystemMessage),
    chan.Writer(PluginMessage),
} {
    const cmd_line = try CommandLine.init(allocator);
    defer cmd_line.deinit();

    const reader, var writer = try CommandLine.read(allocator);

    try writer.write(.{
        .SetVersion = .{
            .major = 0,
            .minor = 1,
        },
    });

    try writer.write(.{
        .SetIndex = cfg.index,
    });

    try writer.write(.Finalize);

    return .{
        reader,
        writer,
    };
}

const CommandLine = struct {
    args: [][:0]u8,
    pos: usize,

    fn read(allocator: std.mem.Allocator) !struct {
        chan.Reader(SystemMessage),
        chan.Writer(PluginMessage),
    } {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        var cmd_line = CommandLine{
            .args = args,
            .pos = 1,
        };

        return .{
            chan.Reader(SystemMessage).init(
                allocator,
                try chan.Channel.import(
                    try cmd_line.next(),
                    try cmd_line.next(),
                    try cmd_line.next(),
                ),
            ),
            chan.Writer(PluginMessage).init(
                allocator,
                try chan.Channel.import(
                    try cmd_line.next(),
                    try cmd_line.next(),
                    try cmd_line.next(),
                ),
            ),
        };
    }

    fn next(self: *@This()) !win.HANDLE {
        if (self.pos >= self.args.len) {
            return error.InvalidArgs;
        }
        const int_ptr = try std.fmt.parseUnsigned(usize, self.args[self.pos], 16);
        self.pos += 1;
        return @ptrFromInt(int_ptr);
    }
};

test {
    _ = @import("def/ObjectScheme.zig");
    _ = @import("def/Type.zig");
    _ = @import("chan/channel.zig");
    _ = @import("chan/serde.zig");

    // TOOD: these tests don't compile due to compiler segfaults
    //_ = @import("obj/write.zig");

    _ = @import("ui/text/bidi.zig");
    _ = @import("ui/text/GlyphAtlas.zig");
    _ = @import("ui/text/GraphemeBreak.zig");
    _ = @import("ui/text/LineBreak.zig");
    _ = @import("ui/text/WordBreak.zig");
}
