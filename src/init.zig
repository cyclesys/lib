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
    SetUI: []const def.TypeId,
    Finalize: void,
};

pub const Version = struct {
    major: u16,
    minor: u16,
};

pub const InitChannel = struct {
    reader: Reader,
    writer: Writer,

    const Reader = chan.Reader(SystemMessage);
    const Writer = chan.Writer(PluginMessage);

    pub fn open(allocator: std.mem.Allocator) !InitChannel {
        const Handles = struct {
            allocator: std.mem.Allocator,
            args: [][:0]u8,
            pos: usize,

            fn init(a: std.mem.Allocator) !@This() {
                const args = try std.process.argsAlloc(a);
                return .{
                    .allocator = a,
                    .args = args,
                    .pos = 1,
                };
            }

            fn deinit(self: *@This()) void {
                std.process.argsFree(self.allocator, self.args);
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

        var handles = try Handles.init(allocator);
        defer handles.deinit();

        const reader = Reader.init(
            allocator,
            try chan.Channel.import(
                try handles.next(),
                try handles.next(),
                try handles.next(),
            ),
        );
        var writer = Writer.init(
            allocator,
            try chan.Channel.import(
                try handles.next(),
                try handles.next(),
                try handles.next(),
            ),
        );

        try writer.write(.{
            .SetVersion = Version{
                .major = 0,
                .minor = 1,
            },
        });

        return InitChannel{
            .reader = reader,
            .writer = writer,
        };
    }

    pub fn read(self: *InitChannel) !chan.View(SystemMessage) {
        return self.reader.read();
    }

    pub fn readFor(self: *InitChannel, timeout: u32) !?chan.View(SystemMessage) {
        return self.reader.readFor(timeout);
    }
};
