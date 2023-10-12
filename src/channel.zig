const std = @import("std");
const win = @import("windows.zig");

const serde = @import("channel/serde.zig");
const SharedMem = @import("SharedMem.zig");

pub fn Reader(comptime Message: type) type {
    return struct {
        chan: Channel,
        buf: std.ArrayList(u8),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, channel: Channel) Self {
            return Self{
                .chan = channel,
                .buf = std.ArrayList(u8).init(allocator),
            };
        }

        pub fn deinit(self: *const Self) void {
            self.buf.deinit();
        }

        pub fn read(self: *Self) !serde.View(Message) {
            const msg = try self.readImpl(null);
            return msg.?;
        }

        pub fn readFor(self: *Self, timeout: u32) !?serde.View(Message) {
            return self.readImpl(timeout);
        }

        fn readImpl(self: *Self, timeout: anytype) !?serde.View(Message) {
            if (!try self.chan.read(&self.buf, timeout)) {
                return null;
            }
            return serde.read(Message, self.buf.items);
        }
    };
}

pub fn Writer(comptime Message: type) type {
    return struct {
        chan: Channel,
        buf: std.ArrayList(u8),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, channel: Channel) Self {
            return Self{
                .chan = channel,
                .buf = std.ArrayList(u8).init(allocator),
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

        fn writeImpl(self: *Self, msg: Message, timeout: anytype) !bool {
            self.buf.clearRetainingCapacity();
            try serde.write(msg, &self.buf);
            return self.chan.write(self.buf.items, timeout);
        }
    };
}

pub const Channel = struct {
    wait_ev: win.HANDLE,
    signal_ev: win.HANDLE,
    mem: SharedMem,
    first_wait: bool = true,

    const size = 1 * 1024;
    const msg_start = @sizeOf(usize);
    const msg_size = size - msg_start;

    pub fn init(start_owned: bool) !Channel {
        const wait_ev = win.CreateEventW(
            null,
            1,
            @intCast(@intFromBool(start_owned)),
            null,
        );
        const signal_ev = win.CreateEventW(
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

    pub fn import(wait_ev: win.HANDLE, signal_ev: win.HANDLE, file: win.HANDLE) !Channel {
        const mem = try SharedMem.import(file, size);
        return Channel{
            .wait_ev = wait_ev,
            .signal_ev = signal_ev,
            .mem = mem,
        };
    }

    pub fn deinit(self: *Channel) !void {
        _ = win.CloseHandle(self.wait_ev);
        _ = win.CloseHandle(self.signal_ev);
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

    fn read(self: *Channel, out: *std.ArrayList(u8), timeout: ?u32) !bool {
        self.first_wait = true;
        out.clearRetainingCapacity();

        while (true) {
            const first_wait = self.first_wait;
            if (!try self.wait(timeout)) {
                return false;
            }

            const remaining = serde.read(usize, self.mem.view);
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

        var pos: usize = 0;
        while (remaining > msg_size) {
            remaining -= msg_size;

            if (!try self.wait(timeout)) {
                return false;
            }

            copyPacked(self.mem.view, remaining);
            @memcpy(self.mem.view[msg_start..], bytes[pos..][0..msg_size]);

            pos += msg_size;

            try self.signal();
        }

        if (remaining > 0) {
            if (!try self.wait(timeout)) {
                return false;
            }

            copyPacked(self.mem.view, @as(usize, 0));
            @memcpy(self.mem.view[msg_start..][0..remaining], bytes[pos..][0..remaining]);

            try self.signal();
        }

        return true;
    }

    fn wait(self: *Channel, timeout: ?u32) !bool {
        const wait_for = if (timeout != null and self.first_wait) timeout.? else win.INFINITE;
        self.first_wait = false;

        const result = win.WaitForSingleObject(self.wait_ev, wait_for);
        return switch (result) {
            win.WAIT_OBJECT_0 => true,
            win.WAIT_TIMEOUT => if (timeout == null) false else error.ChannelInvalid,
            win.WAIT_ABANDONED => error.ChannelInvalid,
            win.WAIT_FAILED => error.ChannelInvalid,
            else => unreachable,
        };
    }

    fn signal(self: *Channel) !void {
        if (win.ResetEvent(self.wait_ev) == 0 or
            win.SetEvent(self.signal_ev) == 0)
        {
            return error.ChannelInvalid;
        }
    }
};

fn copyPacked(dest: []u8, value: anytype) void {
    const len = @sizeOf(@TypeOf(value));
    var source: []const u8 = undefined;
    source.ptr = @ptrCast(&value);
    source.len = len;
    @memcpy(dest[0..len], source);
}

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

            if (msg.field(.str) == null) {
                break;
            }

            try self.writer.write(StrMessage{
                .str = msg.field(.str),
            });
        }

        self.reader.deinit();
        self.writer.deinit();
    }
};

test {
    _ = @import("channel/serde.zig");
}

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
            try testing.expectEqualDeep(str, msg.field(.str));
        }
    }

    child.join();

    try reader.chan.deinit();
    try writer.chan.deinit();
    reader.deinit();
    writer.deinit();
}
