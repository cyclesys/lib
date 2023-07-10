const std = @import("std");
const ucd = @import("ucd/break.zig");

str: []const u8,
offset: usize,
ris_count: usize,
cached_table_item: ucd.GraphemeBreakTableItem,

const Self = @This();

pub fn init(str: []const u8) Self {
    return Self{
        .str = str,
        .offset = 0,
        .ris_count = 0,
        .cached_table_item = .{ 0, 0, .Control },
    };
}

pub fn next(self: *Self) !?[]const u8 {
    if (self.offset == self.str.len) {
        return null;
    }

    const start = self.offset;
    var iter = std.unicode.Utf8Iterator{
        .bytes = self.str[start..],
        .i = 0,
    };

    var code_point = iter.nextCodepointSlice().?;
    var before: ucd.GraphemeBreakProperty = try self.graphemeProperty(code_point, true);
    var after: ucd.GraphemeBreakProperty = undefined;
    var prev_offset = self.offset;
    while (true) {
        self.offset += code_point.len;

        if (before == .Regional_Indicator) {
            self.ris_count += 1;
        } else {
            self.ris_count = 0;
        }

        if (iter.nextCodepointSlice()) |next_code_point| {
            code_point = next_code_point;
            after = try self.graphemeProperty(code_point, true);
        } else {
            if (self.offset != self.str.len) {
                return error.InvalidUtf8;
            }
            return self.str[start..];
        }

        const is_boundary = switch (before) {
            .CR => switch (after) {
                .LF => false,
                else => true,
            },
            .LF => true,
            .Control => true,
            .L => switch (after) {
                .L, .V, .LV, .LVT => false,
                else => defaultAfter(after),
            },
            .LV => switch (after) {
                .V, .T => false,
                else => defaultAfter(after),
            },
            .V => switch (after) {
                .V, .T => false,
                else => defaultAfter(after),
            },
            .LVT => switch (after) {
                .T => false,
                else => defaultAfter(after),
            },
            .T => switch (after) {
                .T => false,
                else => defaultAfter(after),
            },
            .Prepend => switch (after) {
                .CR, .LF, .Control => true,
                else => false,
            },
            .ZWJ => switch (after) {
                .Extended_Pictographic => blk: {
                    var rev_iter = ReverseUtf8Iterator.init(self.str[0..prev_offset]);
                    while (rev_iter.next()) |prev_code_point| {
                        const prev = try self.graphemeProperty(prev_code_point, false);
                        switch (prev) {
                            .Extend => {},
                            .Extended_Pictographic => {
                                break :blk false;
                            },
                            else => {
                                break :blk defaultAfter(after);
                            },
                        }
                    }
                    break :blk defaultAfter(after);
                },
                else => defaultAfter(after),
            },
            .Regional_Indicator => switch (after) {
                .Regional_Indicator => (self.ris_count % 2) == 0,
                else => defaultAfter(after),
            },
            else => defaultAfter(after),
        };

        if (is_boundary) {
            return self.str[start..self.offset];
        }
        before = after;
        prev_offset = self.offset;
    }
}

inline fn defaultAfter(after: ucd.GraphemeBreakProperty) bool {
    return switch (after) {
        .Extend, .ZWJ, .SpacingMark => false,
        else => true,
    };
}

fn graphemeProperty(self: *Self, code_point: []const u8, cache_item: bool) !ucd.GraphemeBreakProperty {
    const unit: u32 = @intCast(try std.unicode.utf8Decode(code_point));
    if (unit <= '\u{7e}') {
        if (unit >= '\u{20}') {
            return .Any;
        } else if (unit == '\n') {
            return .LF;
        } else if (unit == '\r') {
            return .CR;
        }

        return .Control;
    }

    if (self.cached_table_item[0] <= unit and unit <= self.cached_table_item[1]) {
        return self.cached_table_item[2];
    }

    const idx: usize = (unit / ucd.break_lookup_interval);

    const lookup_len = ucd.grapheme_break_lookup.len;
    const lookup_slice = if (idx + 2 <= lookup_len)
        ucd.grapheme_break_table[ucd.grapheme_break_lookup[idx] .. ucd.grapheme_break_lookup[idx + 1] + 1]
    else
        ucd.grapheme_break_table[1443..1449];

    const item: ucd.GraphemeBreakTableItem = switch (bsearchTable(unit, lookup_slice)) {
        .Found => |i| blk: {
            break :blk lookup_slice[i];
        },
        .NotFound => |i| blk: {
            const lower = idx * ucd.break_lookup_interval;
            const upper = lower + ucd.break_lookup_interval - 1;

            const begin = if (i > 0) lookup_slice[i - 1][1] + 1 else lower;
            const end = if (i < lookup_slice.len) lookup_slice[i][0] - 1 else upper;

            break :blk .{ @intCast(begin), @intCast(end), .Any };
        },
    };

    if (cache_item) {
        self.cached_table_item = item;
    }

    return item[2];
}

fn bsearchTable(unit: u32, table: anytype) union(enum) {
    Found: usize,
    NotFound: usize,
} {
    var left: usize = 0;
    var right: usize = table.len;

    while (left < right) {
        const mid = left + (right - left) / 2;
        const item = table[mid];
        const range_begin = item[0];
        const range_end = item[1];

        if (range_begin <= unit and unit <= range_end) {
            return .{ .Found = mid };
        } else if (range_end < unit) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    return .{ .NotFound = left };
}

const ReverseUtf8Iterator = struct {
    bytes: []const u8,
    i: usize,

    fn init(bytes: []const u8) ReverseUtf8Iterator {
        return ReverseUtf8Iterator{
            .bytes = bytes,
            .i = bytes.len,
        };
    }

    fn next(self: *ReverseUtf8Iterator) ?[]const u8 {
        if (self.i == 0) {
            return null;
        }

        var iter = std.mem.reverseIterator(self.bytes[0..self.i]);

        var byte = iter.next().?;
        var len: usize = 1;
        self.i -= 1;
        while (len < 4 and isContByte(byte)) {
            byte = iter.next().?;
            len += 1;
            self.i -= 1;
        }

        return self.bytes[self.i..(self.i + len)];
    }

    inline fn isContByte(code_point: u8) bool {
        return @as(i8, @bitCast(code_point)) < -64;
    }
};

const ucd_test = @import("ucd/break_test.zig");
const GraphemeIterator = @This();

test "reverse iterator" {
    var iter = ReverseUtf8Iterator.init("東京市");
    try std.testing.expect(std.mem.eql(u8, "市", iter.next().?));
    try std.testing.expect(std.mem.eql(u8, "京", iter.next().?));
    try std.testing.expect(std.mem.eql(u8, "東", iter.next().?));
}

test "grapheme break ucd test cases" {
    for (ucd_test.grapheme_test_cases, 0..) |case, i| {
        var iter = GraphemeIterator.init(case[0]);
        const expected = case[1];
        var idx: usize = 0;
        while (try iter.next()) |grapheme| {
            var actual: u32 = undefined;
            var code_point_iter = std.unicode.Utf8Iterator{
                .bytes = grapheme,
                .i = 0,
            };
            while (code_point_iter.nextCodepoint()) |cp| {
                actual = @intCast(cp);
            }
            std.testing.expectEqual(expected[idx], actual) catch |e| {
                std.log.warn("FAILED AT CASE: {} - {}", .{ i, idx });
                return e;
            };
            idx += 1;
        }
        try std.testing.expectEqual(expected.len, idx);
    }
}
