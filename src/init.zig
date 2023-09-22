const std = @import("std");
const windows = struct {
    const mod = @import("win32");
    usingnamespace mod.foundation;
};

const channel = @import("channel.zig");
const definition = @import("definition.zig");
const object = @import("object.zig");

pub const InitChannel = struct {
    reader: Reader,
    writer: Writer,

    const Reader = channel.Reader(SystemMessage);
    const Writer = channel.Writer(PluginMessage);

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

            fn next(self: *@This()) !windows.HANDLE {
                if (self.pos >= self.args.len) {
                    return error.InvalidArgs;
                }
                const int_ptr = try std.fmt.parseUnsigned(usize, self.args[self.pos], 16);
                self.pos += 1;
                return @ptrFromInt(int_ptr);
            }
        };

        var handles = Handles.init(allocator);
        defer handles.deinit();

        const reader = Reader.init(
            allocator,
            try channel.Channel.import(
                try handles.next(),
                try handles.next(),
                try handles.next(),
            ),
        );
        var writer = Writer.init(
            allocator,
            try channel.Channel.import(
                try handles.next(),
                try handles.next(),
                try handles.next(),
            ),
        );

        try writer.write(.{
            .RegisterLibVersion = 1,
        });

        return InitChannel{
            .reader = reader,
            .writer = writer,
        };
    }

    pub fn registerIndexSchemes(self: *InitChannel, schemes: []const definition.ObjectScheme) !void {
        for (schemes) |scheme| {
            try self.writer.write(.{
                .RegisterIndexScheme = scheme,
            });
        }
    }

    pub fn read(self: *InitChannel) !SystemMessage {
        return self.reader.read();
    }

    pub fn readFor(self: *InitChannel, timeout: u32) !?SystemMessage {
        return self.reader.readFor(timeout);
    }
};

pub const SystemMessage = union(enum) {
    InitObjectChannel: ObjectChannelInfo,

    pub const ObjectChannelInfo = struct {
        reader: ObjectChannelReaderInfo,
        writer: ObjectChannelWriterInfo,

        pub const ObjectChannelReaderInfo = ReaderInfo(object.SystemMessage);
        pub const ObjectChannelWriterInfo = WriterInfo(object.PluginMessage);

        pub fn into(
            self: *ObjectChannelInfo,
            comptime Index: type,
            allocator: std.mem.Allocator,
            index: Index,
        ) object.channel.ObjectChannel(Index) {
            return object.ObjectChannel(Index).init(
                allocator,
                try self.reader.into(allocator),
                try self.writer.into(allocator),
                index,
            );
        }
    };

    fn ReaderInfo(comptime Message: type) type {
        return struct {
            chan: ChannelInfo,

            const Reader = channel.Reader(Message);
            const Self = @This();

            pub fn into(
                self: *const Self,
                allocator: std.mem.Allocator,
            ) channel.Error!Reader {
                return Reader.init(allocator, try self.chan.into());
            }
        };
    }

    fn WriterInfo(comptime Message: type) type {
        return struct {
            chan: ChannelInfo,

            const Writer = channel.Writer(Message);
            const Self = @This();

            pub fn into(
                self: *const Self,
                allocator: std.mem.Allocator,
            ) channel.Error!Writer {
                return Writer.init(allocator, try self.chan.into());
            }
        };
    }

    const ChannelInfo = struct {
        wait_ev: usize,
        signal_ev: usize,
        file: usize,

        pub fn into(self: *const ChannelInfo) channel.Error!channel.Channel {
            const wait_ev: windows.HANDLE = @ptrFromInt(self.wait_ev);
            const signal_ev: windows.HANDLE = @ptrFromInt(self.signal_ev);
            const file: windows.HANDLE = @ptrFromInt(self.file);
            return channel.Channel.import(wait_ev, signal_ev, file);
        }
    };
};

const PluginMessage = union(enum) {
    RegisterLibVersion: u16,
    RegisterIndexScheme: definition.ObjectScheme,
};
