const std = @import("std");
const ucd = @import("ucd.zig");
const ReverseUtf8Iterator = @import("ReverseUtf8Iterator.zig");
const GraphemeBreakProperty = @import("ucd/GraphemeBreakProperty.zig");

chars: []const u32,
i: usize,
ris_count: usize,

const Self = @This();

pub fn init(chars: []const u32) Self {
    return Self{
        .chars = chars,
        .i = 0,
        .ris_count = 0,
    };
}

pub fn next(self: *Self) ?usize {
    if (self.i >= self.chars.len) {
        return null;
    }

    const start = self.i;
    var before = ucd.trieValue(GraphemeBreakProperty, self.chars[start]);
    var prev_i = self.i;
    while (true) {
        self.i += 1;

        var after: GraphemeBreakProperty.Value = undefined;
        if (self.i < self.chars.len) {
            after = ucd.trieValue(GraphemeBreakProperty, self.chars[self.i]);
        } else {
            return prev_i;
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
                    var i: usize = prev_i;
                    while (i > 0) : (i -= 1) {
                        const prev = ucd.trieValue(GraphemeBreakProperty, self.chars[i - 1]);
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
            return prev_i;
        }

        before = after;
        prev_i = self.i;
    }
}

inline fn defaultAfter(after: GraphemeBreakProperty.Value) bool {
    return switch (after) {
        .Extend, .ZWJ, .SpacingMark => false,
        else => true,
    };
}

test "GraphemeBreakTest" {
    try ucd.testBreakIterator("GraphemeBreakTest.txt", init);
}
