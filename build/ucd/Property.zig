const std = @import("std");
const util = @import("../util.zig");

allocator: std.mem.Allocator,
entries: Entries,

pub const Entries = std.StringArrayHashMap(RangeList);
pub const RangeList = std.ArrayList(Range);
pub const Range = struct {
    start: u32,
    end: u32,
};
const Self = @This();

pub fn read(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    filters: []const []const u8,
) !Self {
    var self = Self{
        .allocator = allocator,
        .entries = Entries.init(allocator),
    };

    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 10_000_000);
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var range: ?Range = null;
    var name: []const u8 = undefined;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        const info = try parseLine(line);

        if (filters.len > 0) {
            for (filters) |f| {
                if (std.mem.eql(u8, f, info.name)) {
                    break;
                }
            } else {
                continue;
            }
        }

        if (range) |*r| {
            if (info.start != r.end + 1 or !std.mem.eql(u8, name, info.name)) {
                try self.add(name, r.*);
            } else {
                r.end = if (info.end) |end| end else info.start;
                continue;
            }
        }
        range = Range{
            .start = info.start,
            .end = if (info.end) |end| end else info.start,
        };
        name = info.name;
    }
    try self.add(name, range.?);

    return self;
}

fn parseLine(line: []const u8) !struct { start: u32, end: ?u32, name: []const u8 } {
    var split = std.mem.splitAny(u8, line, ";#");
    const range = std.mem.trim(u8, split.next().?, " ");
    const name = std.mem.trim(u8, split.next().?, " ");
    return if (std.mem.indexOfScalar(u8, range, '.')) |i|
        .{
            .start = try std.fmt.parseInt(u32, range[0..i], 16),
            .end = try std.fmt.parseInt(u32, range[i + 2 ..], 16),
            .name = name,
        }
    else
        .{
            .start = try std.fmt.parseInt(u32, range, 16),
            .end = null,
            .name = name,
        };
}

fn add(self: *Self, name: []const u8, range: Range) !void {
    const gop = try self.entries.getOrPut(name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try self.allocator.dupe(u8, name);
        gop.value_ptr.* = RangeList.init(self.allocator);
    }
    try gop.value_ptr.append(range);
}

pub fn extend(self: *Self, other: *const Self) !void {
    var iter = other.entries.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const gop = try self.entries.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
            gop.value_ptr.* = RangeList.init(self.allocator);
        }
        const range_list = entry.value_ptr.*;
        for (range_list.items) |range| {
            try gop.value_ptr.append(range);
        }
    }
}

pub fn deinit(self: *Self) void {
    var iter = self.entries.iterator();
    while (iter.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit();
    }
    self.entries.deinit();
}
