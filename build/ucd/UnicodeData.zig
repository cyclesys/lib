const std = @import("std");

allocator: std.mem.Allocator,
gen_cat: Categories,
bidi_cat: Categories,
entries: Entries,

pub const Categories = std.StringArrayHashMap(void);
pub const Entries = std.ArrayList(Entry);
pub const Entry = struct {
    start: u32,
    end: u32,
    gen_cat: []const u8,
    bidi_cat: []const u8,
};
const Self = @This();

pub fn read(
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !Self {
    var self = Self{
        .allocator = allocator,
        .gen_cat = Categories.init(allocator),
        .bidi_cat = Categories.init(allocator),
        .entries = Entries.init(allocator),
    };

    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 10_000_000);
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var start: ?u32 = null;
    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }

        var items = std.mem.splitScalar(u8, line, ';');
        const code_point = try std.fmt.parseInt(u32, items.next().?, 16);
        const name = items.next().?;
        var gen_cat = items.next().?;
        _ = items.next().?;
        var bidi_cat = items.next().?;

        if (std.mem.endsWith(u8, name, "First>")) {
            start = code_point;
        } else if (std.mem.endsWith(u8, name, "Last>")) {
            const end = code_point;
            try self.entries.append(Entry{
                .start = start.?,
                .end = end,
                .gen_cat = try categoryKey(self.allocator, &self.gen_cat, gen_cat),
                .bidi_cat = try categoryKey(self.allocator, &self.bidi_cat, bidi_cat),
            });
        } else {
            const cp = code_point;
            try self.entries.append(Entry{
                .start = cp,
                .end = cp,
                .gen_cat = try categoryKey(self.allocator, &self.gen_cat, gen_cat),
                .bidi_cat = try categoryKey(self.allocator, &self.bidi_cat, bidi_cat),
            });
        }
    }

    return self;
}

fn categoryKey(allocator: std.mem.Allocator, cats: *Categories, cat: []const u8) ![]const u8 {
    return cats.getKey(cat) orelse {
        var key = try allocator.dupe(u8, cat);
        try cats.put(key, undefined);
        return key;
    };
}

pub fn deinit(self: *Self) void {
    self.entries.deinit();

    for (self.gen_cat.keys()) |str| {
        self.allocator.free(str);
    }
    self.gen_cat.deinit();

    for (self.bidi_cat.keys()) |str| {
        self.allocator.free(str);
    }
    self.bidi_cat.deinit();
}
