const std = @import("std");

allocator: std.mem.Allocator,
categories: Categories,
entries: EntryList,

pub const Categories = std.StringArrayHashMap(void);
pub const EntryList = std.ArrayList(Entry);
pub const Entry = struct {
    start: u32,
    end: u32,
    category: []const u8,
};
const Self = @This();

pub fn read(
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !Self {
    var self = Self{
        .allocator = allocator,
        .categories = Categories.init(allocator),
        .entries = EntryList.init(allocator),
    };

    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 10_000_000);
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var start: ?u32 = null;
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        if (line.len == 0) {
            continue;
        }

        var items = std.mem.splitScalar(u8, line, ';');
        const code_point = try std.fmt.parseInt(u32, items.next().?, 16);
        const name = items.next().?;
        var category = items.next().?;

        if (std.mem.endsWith(u8, name, "First>")) {
            start = code_point;
        } else if (std.mem.endsWith(u8, name, "Last>")) {
            const end = code_point;
            try self.add(start.?, end, category);
        } else {
            const cp = code_point;
            try self.add(cp, cp, category);
        }
    }

    return self;
}

fn add(self: *Self, start: u32, end: u32, category: []const u8) !void {
    var cat_str = self.categories.getKey(category);
    if (cat_str == null) {
        var dup = try self.allocator.dupe(u8, category);
        try self.categories.put(dup, undefined);
        cat_str = dup;
    }
    try self.entries.append(Entry{
        .start = start,
        .end = end,
        .category = cat_str.?,
    });
}

pub fn deinit(self: *Self) void {
    self.entries.deinit();
    for (self.categories.keys()) |str| {
        self.allocator.free(str);
    }
    self.categories.deinit();
}
