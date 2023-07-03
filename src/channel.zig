const std = @import("std");
const windows = @import("windows");

const serde = @import("serde.zig");
const SharedMem = @import("SharedMem.zig");

const ByteList = std.ArrayList(u8);

pub fn Reader(comptime Message: type) type {
    return struct {
        chan: Channel,
        buf: ByteList,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, channel: Channel) Self {
            return Self{
                .chan = channel,
                .buf = ByteList.init(allocator),
            };
        }

        pub fn deinit(self: *const Self) void {
            self.buf.deinit();
        }

        pub fn read(self: *Self) !Message {
            const msg = try self.readImpl(null);
            return msg.?;
        }

        pub fn readFor(self: *Self, timeout: u32) !?Message {
            return self.readImpl(timeout);
        }

        fn readImpl(
            self: *Self,
            timeout: anytype,
        ) !?Message {
            if (!try self.chan.read(&self.buf, timeout)) {
                return null;
            }
            return try serde.deserialize(Message, self.buf.items);
        }
    };
}

pub fn Writer(comptime Message: type) type {
    return struct {
        chan: Channel,
        buf: ByteList,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, channel: Channel) Self {
            return Self{
                .chan = channel,
                .buf = ByteList.init(allocator),
            };
        }

        pub fn deinit(self: *const Self) void {
            self.buf.deinit();
        }

        pub fn write(self: *Self, msg: Message) !void {
            _ = try self.writeImpl(msg, null);
        }

        pub fn writeFor(self: *Self, msg: Message, timeout: u32) !bool {
            return self.writeImpl(msg, timeout);
        }

        fn writeImpl(
            self: *Self,
            msg: Message,
            timeout: anytype,
        ) !bool {
            self.buf.clearRetainingCapacity();
            try serde.serialize(msg, self.buf.writer());
            return self.chan.write(self.buf.items, timeout);
        }
    };
}

pub const Channel = struct {
    wait_ev: windows.HANDLE,
    signal_ev: windows.HANDLE,
    mem: SharedMem,
    first_wait: bool = true,

    const size = 1 * 1024;
    const msg_start = @sizeOf(usize);
    const msg_size = size - msg_start;

    pub fn init(start_owned: bool) !Channel {
        const wait_ev = windows.CreateEventW(
            null,
            1,
            @intCast(@intFromBool(start_owned)),
            null,
        );
        const signal_ev = windows.CreateEventW(
            null,
            1,
            @intCast(@intFromBool(!start_owned)),
            null,
        );

        if (wait_ev == null or signal_ev == null) {
            return error.CreateChannelFailed;
        }

        const mem = try SharedMem.init(size);

        return Channel{
            .wait_ev = wait_ev.?,
            .signal_ev = signal_ev.?,
            .mem = mem,
        };
    }

    pub fn import(
        wait_ev: windows.HANDLE,
        signal_ev: windows.HANDLE,
        file: windows.HANDLE,
    ) !Channel {
        const mem = try SharedMem.import(file, size);
        return Channel{
            .wait_ev = wait_ev,
            .signal_ev = signal_ev,
            .mem = mem,
        };
    }

    pub fn deinit(self: *Channel) !void {
        _ = windows.CloseHandle(self.wait_ev);
        _ = windows.CloseHandle(self.signal_ev);
        self.mem.deinit();
    }

    pub fn reversed(self: *const Channel) Channel {
        return Channel{
            .wait_ev = self.signal_ev,
            .signal_ev = self.wait_ev,
            .mem = self.mem,
            .first_wait = true,
        };
    }

    fn read(self: *Channel, out: *ByteList, timeout: ?u32) !bool {
        self.first_wait = true;
        out.clearRetainingCapacity();

        while (true) {
            const first_wait = self.first_wait;
            if (!try self.wait(timeout)) {
                return false;
            }

            const remaining = try serde.deserialize(usize, self.mem.view);

            if (first_wait) {
                try out.ensureTotalCapacity(msg_size + remaining);
            }

            try out.appendSlice(self.mem.view[msg_start..]);
            try self.signal();

            if (remaining == 0) {
                break;
            }
        }

        return true;
    }

    fn write(self: *Channel, bytes: []const u8, timeout: ?u32) !bool {
        self.first_wait = true;

        var remaining = bytes.len;
        var stream = std.io.fixedBufferStream(self.mem.view);
        var writer = stream.writer();

        var pos: usize = 0;
        while (remaining > msg_size) {
            remaining -= msg_size;

            if (!try self.wait(timeout)) {
                return false;
            }

            try serde.serialize(remaining, writer);

            // This does not use `serde.serialize` because `serde.serialize` would serialize the length
            // of the slice as well as the bytes, which we don't want.
            //
            // Instead we use `@memcpy` to copy the bytes directly into the view.
            @memcpy(self.mem.view[msg_start..], bytes[pos..(pos + msg_size)]);

            pos += msg_size;
            stream.reset();

            try self.signal();
        }

        if (remaining > 0) {
            if (!try self.wait(timeout)) {
                return false;
            }

            try serde.serialize(@as(usize, 0), writer);

            // This does not use `serde.serialize` because `serde.serialize` would serialize the length
            // of the slice as well as the bytes, which we don't want.
            //
            // Instead we use `@memcpy` to copy the bytes directly into the view.
            @memcpy(self.mem.view[msg_start..(msg_start + remaining)], bytes[pos..(pos + remaining)]);

            try self.signal();
        }

        return true;
    }

    fn wait(self: *Channel, timeout: ?u32) !bool {
        const wait_for = if (timeout != null and self.first_wait) timeout.? else windows.INFINITE;
        self.first_wait = false;

        const result = windows.WaitForSingleObject(self.wait_ev, wait_for);
        return switch (result) {
            windows.WAIT_OBJECT_0 => true,
            windows.WAIT_TIMEOUT => if (timeout == null) false else error.ChannelInvalid,
            windows.WAIT_ABANDONED => error.ChannelInvalid,
            windows.WAIT_FAILED => error.ChannelInvalid,
            else => unreachable,
        };
    }

    fn signal(self: *Channel) !void {
        if (windows.ResetEvent(self.wait_ev) == 0 or
            windows.SetEvent(self.signal_ev) == 0)
        {
            return error.ChannelInvalid;
        }
    }
};

const testing = std.testing;
const StrMessage = struct {
    str: ?[]const u8,
};
const MessageReader = Reader(StrMessage);
const MessageWriter = Writer(StrMessage);
const Child = struct {
    reader: MessageReader,
    writer: MessageWriter,

    fn run(self: *Child) !void {
        while (true) {
            const msg = try self.reader.read();

            if (msg.str == null) {
                break;
            }

            try self.writer.write(msg);
        }

        self.reader.deinit();
        self.writer.deinit();
    }
};

test "channel io without timeout" {
    var reader = MessageReader.init(testing.allocator, try Channel.init(false));
    var writer = MessageWriter.init(testing.allocator, try Channel.init(true));

    const child = try std.Thread.spawn(.{}, Child.run, .{@constCast(&Child{
        .reader = MessageReader.init(testing.allocator, writer.chan.reversed()),
        .writer = MessageWriter.init(testing.allocator, reader.chan.reversed()),
    })});

    for (0..3) |i| {
        const str: ?[]const u8 = switch (i) {
            0 => "Hello",
            1 => "World",
            2 => null,
            else => unreachable,
        };
        try writer.write(StrMessage{ .str = str });
        if (str != null) {
            const msg = try reader.read();
            try testing.expectEqualDeep(str, msg.str);
        }
    }

    child.join();

    try reader.chan.deinit();
    try writer.chan.deinit();
    reader.deinit();
    writer.deinit();
}
