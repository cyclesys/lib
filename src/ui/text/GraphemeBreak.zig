const std = @import("std");
const ucd = @import("ucd.zig");
const ReverseUtf8Iterator = @import("ReverseUtf8Iterator.zig");
const GraphemeBreakProperty = @import("ucd/GraphemeBreakProperty.zig");

str: []const u8,
offset: usize,
ris_count: usize,

const Self = @This();

pub fn init(str: []const u8) Self {
    return Self{
        .str = str,
        .offset = 0,
        .ris_count = 0,
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
    var before = try ucd.trieValue(GraphemeBreakProperty, code_point);
    var prev_offset = self.offset;
    while (true) {
        self.offset += code_point.len;

        var after: GraphemeBreakProperty.Value = undefined;
        if (iter.nextCodepointSlice()) |next_code_point| {
            code_point = next_code_point;
            after = try ucd.trieValue(GraphemeBreakProperty, code_point);
        } else {
            if (self.offset != self.str.len) {
                return error.InvalidUtf8;
            }
            return self.str[start..];
        }

        if (before == .Regional_Indicator) {
            self.ris_count += 1;
        } else {
            self.ris_count = 0;
        }

        const can_break = switch (before) {
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
            .ZWJ => blk: {
                if (after == .Extended_Pictographic) {
                    var rev_iter = ReverseUtf8Iterator.init(self.str[0..prev_offset]);
                    while (rev_iter.next()) |prev_code_point| {
                        const prev = try ucd.trieValue(GraphemeBreakProperty, prev_code_point);
                        switch (prev) {
                            .Extend => {},
                            .Extended_Pictographic => {
                                break :blk false;
                            },
                            else => {
                                break;
                            },
                        }
                    }
                }
                break :blk defaultAfter(after);
            },
            .Regional_Indicator => switch (after) {
                .Regional_Indicator => (self.ris_count % 2) == 0,
                else => defaultAfter(after),
            },
            else => defaultAfter(after),
        };

        if (can_break) {
            return self.str[start..self.offset];
        }

        before = after;
        prev_offset = self.offset;
    }
}

inline fn defaultAfter(after: GraphemeBreakProperty.Value) bool {
    return switch (after) {
        .Extend, .ZWJ, .SpacingMark => false,
        else => true,
    };
}

const GraphemeBreakTest = @import("ucd/GraphemeBreakTest.zig");
test {
    try ucd.breakTest(GraphemeBreakTest, init);
}
