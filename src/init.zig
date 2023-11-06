const std = @import("std");
const win = @import("windows.zig");

const chan = @import("lib.zig").chan;
const def = @import("lib.zig").def;

pub const SystemMessage = union(enum) {
    fn ReaderInfo(comptime Message: type) type {
        return struct {
            chan: ChannelInfo,

            const Reader = chan.Reader(Message);
            const Self = @This();

            pub fn into(self: *const Self, allocator: std.mem.Allocator) chan.Error!Reader {
                return Reader.init(allocator, try self.chan.into());
            }
        };
    }

    fn WriterInfo(comptime Message: type) type {
        return struct {
            chan: ChannelInfo,

            const Writer = chan.Writer(Message);
            const Self = @This();

            pub fn into(self: *const Self, allocator: std.mem.Allocator) chan.Error!Writer {
                return Writer.init(allocator, try self.chan.into());
            }
        };
    }

    const ChannelInfo = struct {
        wait_ev: usize,
        signal_ev: usize,
        file: usize,

        pub fn into(self: *const ChannelInfo) chan.Error!chan.Channel {
            const wait_ev: win.HANDLE = @ptrFromInt(self.wait_ev);
            const signal_ev: win.HANDLE = @ptrFromInt(self.signal_ev);
            const file: win.HANDLE = @ptrFromInt(self.file);
            return chan.Channel.import(wait_ev, signal_ev, file);
        }
    };
};

pub const PluginMessage = union(enum) {
    SetVersion: Version,
    SetIndex: []const def.ObjectScheme,
    Finalize: void,
};

pub const Version = struct {
    major: u16,
    minor: u16,
};

pub const InitConfig = struct {
    index: []const def.ObjectScheme,
};

pub const InitResult = struct {};

pub fn init(allocator: std.mem.Allocator, cfg: InitConfig) !InitResult {
    const cmd_line = try CommandLine.init(allocator);
    defer cmd_line.deinit();

    var reader, var writer = try CommandLine.read(allocator);
    _ = reader;

    try writer.write(.{
        .SetVersion = Version{
            .major = 0,
            .minor = 1,
        },
    });

    try writer.write(.{
        .SetIndex = cfg.index,
    });

    try writer.write(.Finalize);

    return InitResult{};
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
