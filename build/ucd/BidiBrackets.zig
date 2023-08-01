const std = @import("std");

allocator: std.mem.Allocator,
entries: Entries,

pub const Entries = std.ArrayList(Entry);
pub const Entry = struct {
    left: u32,
    right: u32,
    kind: enum { opening, closing },
};
const Self = @This();

pub fn read(allocator: std.mem.Allocator, file_path: []const u8) !Self {
    var entries = Entries.init(allocator);

    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 10_000_000);
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        var split = std.mem.splitAny(u8, line, ";#");
        const left = try std.fmt.parseInt(u32, std.mem.trim(u8, split.next().?, " "), 16);
        const right = try std.fmt.parseInt(u32, std.mem.trim(u8, split.next().?, " "), 16);
        const kind = std.mem.trim(u8, split.next().?, " ");
        try entries.append(Entry{
            .left = left,
            .right = right,
            .kind = switch (kind[0]) {
                'o' => .opening,
                'c' => .closing,
                else => @panic("unexpected bidi bracket pair kind"),
            },
        });
    }

    return Self{
        .allocator = allocator,
        .entries = entries,
    };
}

pub fn deinit(self: Self) void {
    self.entries.deinit();
}
