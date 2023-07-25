const std = @import("std");
const ReverseUtf8Iterator = @import("ReverseUtf8Iterator.zig");

pub fn trieValue(comptime Trie: type, code_point: []const u8) !Trie.Value {
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

    const c: u32 = @intCast(try std.unicode.utf8Decode(code_point));
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

pub fn breakTest(comptime BreakTest: type, initFn: anytype) !void {
    for (BreakTest.cases) |case| {
        var iter = initFn(case[0]);
        const expected = case[1];
        for (expected) |exp| {
            const grapheme = if (try iter.next()) |slice| slice else return error.TestExpectedMoreGraphemes;
            var grapheme_iter = ReverseUtf8Iterator.init(grapheme);
            const break_code_point = grapheme_iter.next().?;
            const actual: u32 = @intCast(try std.unicode.utf8Decode(break_code_point));
            try std.testing.expectEqual(exp, actual);
        }
        try std.testing.expectEqual(@as(?[]const u8, null), try iter.next());
    }
}
