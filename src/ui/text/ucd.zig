const std = @import("std");
const ReverseUtf8Iterator = @import("ReverseUtf8Iterator.zig");

pub fn trieValue(comptime Trie: type, c: []const u8) !Trie.Value {
    return trieValueDecoded(Trie, try std.unicode.utf8Decode(c));
}

pub fn trieValueDecoded(comptime Trie: type, c: u32) Trie.Value {
    const FAST_SHIFT = 6;
    const FAST_DATA_BLOCK_LEN = 1 << FAST_SHIFT;
    const FAST_DATA_MASK = FAST_DATA_BLOCK_LEN - 1;
    const SHIFT_3 = 4;
    const SHIFT_2 = 5 + SHIFT_3;
    const SHIFT_1 = 5 + SHIFT_2;
    const SHIFT_1_2 = SHIFT_1 - SHIFT_2;
    const SHIFT_2_3 = SHIFT_2 - SHIFT_3;
    const SMALL_DATA_BLOCK_LEN = 1 << SHIFT_3;
    const SMALL_DATA_MASK = SMALL_DATA_BLOCK_LEN - 1;
    const INDEX_2_BLOCK_LEN = 1 << SHIFT_1_2;
    const INDEX_2_MASK = INDEX_2_BLOCK_LEN - 1;
    const INDEX_3_BLOCK_LEN = 1 << SHIFT_2_3;
    const INDEX_3_MASK = INDEX_3_BLOCK_LEN - 1;
    const BMP_INDEX_LEN = 0x10000 >> FAST_SHIFT;
    const OMITTED_BMP_INDEX_1_LEN = 0x10000 >> SHIFT_1;
    const ERROR_VALUE_NEG_DATA_OFFSET = 1;
    const HIGH_VALUE_NEG_DATA_OFFSET = 2;

    if (c <= 0xFFFF) {
        return Trie.data[Trie.index[c >> FAST_SHIFT] + (c & FAST_DATA_MASK)];
    }
    if (c > 0x10FFFF) {
        return Trie.data[Trie.data.len - ERROR_VALUE_NEG_DATA_OFFSET];
    }
    if (c >= Trie.high_start) {
        return Trie.data[Trie.data.len - HIGH_VALUE_NEG_DATA_OFFSET];
    }

    const idx1: u32 = (c >> SHIFT_1) + (BMP_INDEX_LEN - OMITTED_BMP_INDEX_1_LEN);
    var idx3_block: u32 = Trie.index[Trie.index[idx1] + ((c >> SHIFT_2) & INDEX_2_MASK)];
    var idx3: u32 = (c >> SHIFT_3) & INDEX_3_MASK;
    var data_block: u32 = undefined;
    if ((idx3_block & 0x8000) == 0) {
        data_block = Trie.index[idx3_block + idx3];
    } else {
        idx3_block = (idx3_block & 0x7FFF) + (idx3 & ~@as(u32, 7)) + (idx3 >> 3);
        idx3 &= 7;
        data_block = @as(u32, @intCast(Trie.index[idx3_block] << @intCast((2 + (2 * idx3))))) & 0x30000;
        data_block |= Trie.index[idx3_block + idx3];
    }
    return Trie.data[data_block + (c & SMALL_DATA_MASK)];
}

pub fn testBreakIterator(comptime name: []const u8, initFn: anytype) !void {
    const test_data = @embedFile("ucd/" ++ name);
    const allocator = std.testing.allocator;

    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();

    var breaks = std.ArrayList(u32).init(allocator);
    defer breaks.deinit();

    var lines = std.mem.splitScalar(u8, test_data, '\n');
    var line_num: usize = 1;
    while (lines.next()) |line| : (line_num += 1) {
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        var iter = std.unicode.Utf8Iterator{ .bytes = line, .i = 0 };
        var unit_start: usize = 0;
        var code_point_start: ?usize = null;
        var code_point: ?u32 = null;
        while (iter.nextCodepointSlice()) |slice| : (unit_start += slice.len) {
            const unit = try std.unicode.utf8Decode(slice);
            switch (unit) {
                '÷' => {
                    if (code_point) |cp| {
                        try breaks.append(cp);
                        code_point = null;
                    }
                },
                '×' => {
                    code_point = null;
                },
                ' ' => {
                    if (code_point_start) |start| {
                        const c = try std.fmt.parseInt(u21, line[start..unit_start], 16);

                        var out: [4]u8 = undefined;
                        const out_len = try std.unicode.utf8Encode(c, &out);
                        try string.appendSlice(out[0..out_len]);

                        code_point = c;
                        code_point_start = null;
                    }
                },
                '0'...'9', 'A'...'F' => {
                    if (code_point_start == null) {
                        if (code_point != null) {
                            @panic("unconsumed code point");
                        }
                        code_point_start = unit_start;
                    }
                },
                '#' => {
                    break;
                },
                else => {
                    // ignore everything else
                },
            }
        }

        expectBreaks(string.items, breaks.items, initFn) catch |e| {
            std.debug.print("Line: {}\n", .{line_num});
            return e;
        };

        string.clearRetainingCapacity();
        breaks.clearRetainingCapacity();
    }
}

fn expectBreaks(string: []const u8, breaks: []const u32, initFn: anytype) !void {
    var iter = initFn(string);
    for (breaks) |expected| {
        const segment = if (try iter.next()) |slice| slice else return error.ExpectedMoreBreaks;
        var segment_iter = ReverseUtf8Iterator.init(segment);
        const break_code_point = segment_iter.next().?;
        const actual: u32 = try std.unicode.utf8Decode(break_code_point);
        std.testing.expectEqual(expected, actual) catch {
            return error.ExpectedBreakEqual;
        };
    }
    std.testing.expectEqual(@as(?[]const u8, null), try iter.next()) catch {
        return error.ExpectedNoMoreBreaks;
    };
}
