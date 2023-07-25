const std = @import("std");

allocator: std.mem.Allocator,

index: []u32,
index3_null_offset: ?u32,

data: []u32,
data_len: u32,
data_null_offset: ?u32,

original_initial_value: u32,
initial_value: u32,
error_value: u32,

high_start: u32,
high_value: u32,

index16: []u16,
flags: [FLAGS_LEN]u2,

pub const Trie = struct {
    allocator: std.mem.Allocator,
    index: []const u16,
    data: []const u8,
    high_start: u32,

    pub fn deinit(self: Trie) void {
        self.allocator.free(self.index);
        self.allocator.free(self.data);
    }
};

const Self = @This();

pub fn init(allocator: std.mem.Allocator, initial_value: u32, error_value: u32) !Self {
    const index = try allocator.alloc(u32, BMP_I_LIMIT);
    @memset(index, 0);

    const data = try allocator.alloc(u32, INITIAL_DATA_LEN);
    @memset(data, 0);

    return Self{
        .allocator = allocator,
        .index = index,
        .index3_null_offset = null,
        .data = data,
        .data_len = 0,
        .data_null_offset = null,
        .original_initial_value = initial_value,
        .initial_value = initial_value,
        .error_value = error_value,
        .high_start = 0,
        .high_value = initial_value,
        .index16 = undefined,
        .flags = [_]u2{0} ** FLAGS_LEN,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.index);
    self.allocator.free(self.data);
    self.allocator.free(self.index16);
}

fn ensureCapacity(self: *Self, slice: []u32, capacity: usize) ![]u32 {
    if (slice.len < capacity) {
        const new_slice = try self.allocator.alloc(u32, capacity);
        @memcpy(new_slice[0..slice.len], slice);
        @memset(new_slice[slice.len..], 0);
        self.allocator.free(slice);
        return new_slice;
    }
    return slice;
}

pub fn setRange(self: *Self, s: u32, e: u32, value: u32) !void {
    var start: u32 = s;
    var end: u32 = e;
    if (start > MAX_UNICODE or end > MAX_UNICODE or start > end) {
        return error.InvalidRange;
    }
    try self.ensureHighStart(end);

    var limit: u32 = end + 1;
    if (start & SMALL_DATA_MASK != 0) {
        var block_start = try self.getDataBlock(start >> SHIFT_3);
        const next_start = (start + SMALL_DATA_MASK) & ~SMALL_DATA_MASK;
        if (next_start > limit) {
            const block_end = block_start + (limit & SMALL_DATA_MASK);
            block_start += (start & SMALL_DATA_MASK);
            @memset(self.data[block_start..block_end], value);
            return;
        }

        const block_end = block_start + SMALL_DATA_BLOCK_LEN;
        block_start += (start & SMALL_DATA_MASK);
        @memset(self.data[block_start..block_end], value);
        start = next_start;
    }

    const rest = limit & SMALL_DATA_MASK;
    limit &= ~SMALL_DATA_MASK;

    while (start < limit) {
        const i = start >> SHIFT_3;
        if (self.flags[i] == ALL_SAME) {
            self.index[i] = value;
        } else {
            const block_start = self.index[i];
            @memset(self.data[block_start..][0..SMALL_DATA_BLOCK_LEN], value);
        }
        start += SMALL_DATA_BLOCK_LEN;
    }

    if (rest > 0) {
        const block_start = try self.getDataBlock(start >> SHIFT_3);
        const block_end = block_start + @as(usize, @intCast(rest));
        @memset(self.data[block_start..block_end], value);
    }
}

fn ensureHighStart(self: *Self, cc: u32) !void {
    var c = cc;
    if (c >= self.high_start) {
        c = (c + CP_PER_INDEX_2_ENTRY) & ~(CP_PER_INDEX_2_ENTRY - 1);

        var i = self.high_start >> SHIFT_3;
        const i_limit = c >> SHIFT_3;
        if (i_limit > self.index.len) {
            self.index = try self.ensureCapacity(self.index, I_LIMIT);
        }

        while (true) {
            self.flags[i] = ALL_SAME;
            self.index[i] = self.initial_value;
            i += 1;
            if (i < i_limit) continue else break;
        }
        self.high_start = c;
    }
}

fn getDataBlock(self: *Self, i: u32) !usize {
    if (self.flags[i] == MIXED) {
        return self.index[i];
    }

    if (i < BMP_I_LIMIT) {
        var block_start = try self.allocDataBlock(FAST_DATA_BLOCK_LEN);
        var i_start = i & ~(SMALL_DATA_BLOCKS_PER_BMP_BLOCK - 1);
        const i_limit = i_start + SMALL_DATA_BLOCKS_PER_BMP_BLOCK;
        while (true) {
            @memset(self.data[block_start..][0..SMALL_DATA_BLOCK_LEN], self.index[i_start]);
            self.flags[i_start] = MIXED;
            self.index[i_start] = block_start;
            block_start += SMALL_DATA_BLOCK_LEN;
            i_start += 1;
            if (i_start < i_limit) continue else break;
        }
        return self.index[i];
    }

    var block_start = try self.allocDataBlock(SMALL_DATA_BLOCK_LEN);
    @memset(self.data[block_start..][0..SMALL_DATA_BLOCK_LEN], self.index[i]);
    self.flags[i] = MIXED;
    self.index[i] = block_start;
    return block_start;
}

fn allocDataBlock(self: *Self, block_len: u32) !u32 {
    const block_start = self.data_len;
    const block_end = block_start + block_len;
    if (block_end > self.data.len) {
        const capacity = if (self.data.len < MEDIUM_DATA_LEN)
            MEDIUM_DATA_LEN
        else if (self.data.len < MAX_DATA_LEN)
            MAX_DATA_LEN
        else
            return error.DataOverCapacity;

        self.data = try self.ensureCapacity(self.data, capacity);
    }
    self.data_len = block_end;
    return block_start;
}

pub fn build(self: *Self) !Trie {
    // mask off values to 8 bits
    self.maskValues(0xFF);

    const index_len = try self.compactTrie();

    var and3 = ((index_len * 2) + self.data_len) & 3;
    if (and3 == 0 and self.data[self.data_len - 1] == self.error_value and self.data[self.data_len - 2] == self.high_value) {
        // all set
    } else if (and3 == 3 and self.data[self.data_len - 1] == self.high_value) {
        self.data[self.data_len] = self.error_value;
        self.data_len += 1;
    } else {
        while (and3 != 2) {
            self.data[self.data_len] = self.high_value;
            self.data_len += 1;

            and3 += 1;
            and3 &= 3;
        }
        self.data[self.data_len] = self.high_value;
        self.data_len += 1;
        self.data[self.data_len] = self.error_value;
        self.data_len += 1;
    }

    var index = try self.allocator.alloc(u16, index_len);
    var data = try self.allocator.alloc(u8, self.data_len);
    if (self.high_start <= BMP_LIMIT) {
        var i: usize = 0;
        for (0..index_len) |j| {
            index[j] = @intCast(self.index[i]);
            i += SMALL_DATA_BLOCKS_PER_BMP_BLOCK;
        }
    } else {
        @memcpy(index, self.index16[0..index_len]);
    }

    for (0..self.data_len) |i| {
        data[i] = @intCast(self.data[i]);
    }

    return Trie{
        .allocator = self.allocator,
        .index = index,
        .data = data,
        .high_start = self.high_start,
    };
}

fn maskValues(self: *Self, mask: u32) void {
    self.initial_value &= mask;
    self.error_value &= mask;
    self.high_value &= mask;

    const i_limit = self.high_start >> SHIFT_3;
    for (0..i_limit) |i| {
        if (self.flags[i] == ALL_SAME) {
            self.index[i] &= mask;
        }
    }

    for (0..self.data_len) |i| {
        self.data[i] &= mask;
    }
}

fn compactTrie(self: *Self) !u32 {
    self.high_value = self.get(MAX_UNICODE);

    var real_high_start = self.findHighStart();
    real_high_start += (CP_PER_INDEX_2_ENTRY - 1);
    real_high_start &= ~(CP_PER_INDEX_2_ENTRY - 1);
    if (real_high_start == UNICODE_LIMIT) {
        self.high_value = self.initial_value;
    }

    if (real_high_start < BMP_LIMIT) {
        for ((real_high_start >> SHIFT_3)..BMP_I_LIMIT) |i| {
            self.flags[i] = ALL_SAME;
            self.index[i] = self.high_value;
        }
        self.high_start = BMP_LIMIT;
    } else {
        self.high_start = real_high_start;
    }

    var ascii_data: [ASCII_LIMIT]u32 = undefined;
    for (0..ASCII_LIMIT) |i| {
        ascii_data[i] = self.get(@intCast(i));
    }

    var all_same_blocks = AllSameBlocks{};
    const new_data_capacity = try self.compactWholeDataBlocks(&all_same_blocks);

    const new_data = try self.allocator.alloc(u32, new_data_capacity);
    @memcpy(new_data[0..ASCII_LIMIT], &ascii_data);
    @memset(new_data[ASCII_LIMIT..], 0);

    const data_null_index = all_same_blocks.findMostUsed();

    var mixed_blocks = MixedBlocks.init(self.allocator);
    defer mixed_blocks.deinit();

    const new_data_len = try self.compactData(new_data, data_null_index, &mixed_blocks);
    std.debug.assert(new_data_len <= new_data_capacity);
    self.allocator.free(self.data);
    self.data = new_data;
    self.data_len = new_data_len;

    if (self.data_len > (0x3FFFF + SMALL_DATA_BLOCK_LEN)) {
        return error.DataOutOfIndexBounds;
    }

    if (data_null_index) |dni| {
        self.data_null_offset = self.index[dni];
        self.initial_value = self.data[self.data_null_offset.?];
    } else {
        self.data_null_offset = NO_DATA_NULL_OFFSET;
    }

    const index_len = try self.compactIndex(&mixed_blocks);
    self.high_start = real_high_start;
    return index_len;
}

fn get(self: *Self, c: u32) u32 {
    if (c >= self.high_start) {
        return self.high_value;
    }

    const i = c >> SHIFT_3;
    if (self.flags[i] == ALL_SAME) {
        return self.index[i];
    }

    return self.data[self.index[i] + (c & SMALL_DATA_MASK)];
}

fn findHighStart(self: *Self) u32 {
    var i = self.high_start >> SHIFT_3;
    while (i > 0) {
        var match: bool = undefined;
        i -= 1;
        if (self.flags[i] == ALL_SAME) {
            match = self.index[i] == self.high_value;
        } else {
            const p = self.data[self.index[i]..];
            var j: u32 = 0;
            while (true) : (j += 1) {
                if (j == SMALL_DATA_BLOCK_LEN) {
                    match = true;
                    break;
                }
                if (p[j] != self.high_value) {
                    match = false;
                    break;
                }
            }
        }
        if (!match) {
            return (i + 1) << SHIFT_3;
        }
    }
    return 0;
}

fn compactWholeDataBlocks(self: *Self, all_same_blocks: *AllSameBlocks) !u32 {
    var new_data_capacity: u32 = ASCII_LIMIT;
    new_data_capacity += SMALL_DATA_BLOCK_LEN;
    new_data_capacity += 4;

    const i_limit = self.high_start >> SHIFT_3;
    var block_len: u32 = FAST_DATA_BLOCK_LEN;
    var inc: u32 = SMALL_DATA_BLOCKS_PER_BMP_BLOCK;
    var i: u32 = 0;
    while (i < i_limit) : (i += inc) {
        if (i == BMP_I_LIMIT) {
            block_len = SMALL_DATA_BLOCK_LEN;
            inc = 1;
        }
        var value = self.index[i];
        if (self.flags[i] == MIXED) {
            const p = self.data[value..];
            value = p[0];
            if (std.mem.allEqual(u32, p[1..][0 .. block_len - 1], value)) {
                self.flags[i] = ALL_SAME;
                self.index[i] = value;
            } else {
                new_data_capacity += block_len;
                continue;
            }
        } else {
            std.debug.assert(self.flags[i] == ALL_SAME);
            if (inc > 1) {
                var all_same = true;
                for ((i + 1)..(i + inc)) |j| {
                    std.debug.assert(self.flags[j] == ALL_SAME);
                    if (self.index[j] != value) {
                        all_same = false;
                        break;
                    }
                }
                if (!all_same) {
                    _ = try self.getDataBlock(i);
                    new_data_capacity += block_len;
                    continue;
                }
            }
        }

        const other = switch (all_same_blocks.findOrAdd(i, inc, value)) {
            .Found => |v| v,
            .Added => null,
            .Overflow => blk: {
                var j_inc: u32 = SMALL_DATA_BLOCKS_PER_BMP_BLOCK;
                var j: u32 = 0;
                while (true) : (j += j_inc) {
                    if (j == i) {
                        all_same_blocks.add(i, inc, value);
                        break :blk null;
                    }
                    if (j == BMP_I_LIMIT) {
                        j_inc = 1;
                    }
                    if (self.flags[j] == ALL_SAME and self.index[j] == value) {
                        all_same_blocks.add(j, j_inc + inc, value);
                        break :blk j;
                    }
                }
            },
        };

        if (other) |o| {
            self.flags[i] = SAME_AS;
            self.index[i] = o;
        } else {
            new_data_capacity += block_len;
        }
    }
    return new_data_capacity;
}

fn compactData(
    self: *Self,
    new_data: []u32,
    data_null_index: ?u32,
    mixed_blocks: *MixedBlocks,
) !u32 {
    var new_data_len: u32 = 0;
    var i: u32 = 0;
    while (new_data_len < ASCII_LIMIT) {
        self.index[i] = new_data_len;
        new_data_len += FAST_DATA_BLOCK_LEN;
        i += SMALL_DATA_BLOCKS_PER_BMP_BLOCK;
    }

    var block_len: u32 = FAST_DATA_BLOCK_LEN;
    try mixed_blocks.reset(@intCast(new_data.len), block_len);
    try mixed_blocks.extend(u32, new_data, 0, 0, new_data_len);

    const i_limit = self.high_start >> SHIFT_3;
    var inc: u32 = SMALL_DATA_BLOCKS_PER_BMP_BLOCK;
    var fast_len: u32 = 0;
    i = ASCII_I_LIMIT;
    while (i < i_limit) : (i += inc) {
        if (i == BMP_I_LIMIT) {
            block_len = SMALL_DATA_BLOCK_LEN;
            inc = 1;
            fast_len = new_data_len;
            try mixed_blocks.reset(@intCast(new_data.len), block_len);
            try mixed_blocks.extend(u32, new_data, 0, 0, new_data_len);
        }

        switch (self.flags[i]) {
            ALL_SAME => {
                const value = self.index[i];
                var n = mixed_blocks.findBlockValue(new_data, value);

                if (data_null_index != null and
                    i == data_null_index.? and
                    i >= BMP_I_LIMIT)
                {
                    while (n != null and
                        n.? < fast_len and
                        self.isStartOfSomeFastBlock(n.?))
                    {
                        n = findAllSameBlock(new_data, n.? + 1, new_data_len, value, block_len);
                    }
                }

                if (n) |nn| {
                    self.index[i] = nn;
                } else {
                    var k = getAllSameOverlap(new_data, new_data_len, value, block_len);

                    self.index[i] = new_data_len - k;
                    const prev_data_len = new_data_len;
                    while (k < block_len) {
                        new_data[new_data_len] = value;
                        new_data_len += 1;
                        k += 1;
                    }
                    try mixed_blocks.extend(u32, new_data, 0, prev_data_len, new_data_len);
                }
            },
            MIXED => {
                const block = self.data[self.index[i]..];
                if (mixed_blocks.findBlock(u32, u32, new_data, block)) |n| {
                    self.index[i] = n;
                } else {
                    var n = getOverlap(u32, u32, new_data, new_data_len, block, block_len);
                    self.index[i] = new_data_len - n;
                    const prev_data_len = new_data_len;
                    while (n < block_len) {
                        new_data[new_data_len] = block[n];
                        new_data_len += 1;
                        n += 1;
                    }
                    try mixed_blocks.extend(u32, new_data, 0, prev_data_len, new_data_len);
                }
            },
            SAME_AS => {
                const j = self.index[i];
                self.index[i] = self.index[j];
            },
            else => unreachable,
        }
    }

    return new_data_len;
}

fn isStartOfSomeFastBlock(self: *const Self, offset: u32) bool {
    var i: usize = 0;
    while (i < BMP_I_LIMIT) : (i += SMALL_DATA_BLOCKS_PER_BMP_BLOCK) {
        if (self.index[i] == offset) {
            return true;
        }
    }
    return false;
}

fn findAllSameBlock(p: []const u32, start: u32, limit: u32, value: u32, block_len: u32) ?u32 {
    const block_limit = limit - block_len;
    var block = start;
    while (block <= block_limit) : (block += 1) {
        if (p[block] == value) {
            var i: u32 = 1;
            while (true) : (i += 1) {
                if (i == block_len) {
                    return block;
                }
                if (p[block + 1] != value) {
                    block += i;
                    break;
                }
            }
        }
    }
    return null;
}

fn getAllSameOverlap(p: []const u32, len: u32, value: u32, block_len: u32) u32 {
    var min = len - block_len - 1;
    var i = len;
    while (min < i and p[i - 1] == value) {
        i -= 1;
    }
    return len - i;
}

fn compactIndex(self: *Self, mixed_blocks: *MixedBlocks) !u32 {
    const fast_index_len = BMP_I_LIMIT >> (FAST_SHIFT - SHIFT_3);
    if ((self.high_start >> FAST_SHIFT) <= fast_index_len) {
        self.index3_null_offset = NO_INDEX3_NULL_OFFSET;
        return fast_index_len;
    }

    var fast_index: [BMP_INDEX_LEN]u16 = undefined;
    var idx3_first_null: ?u32 = null;
    var i: u32 = 0;
    var j: u32 = 0;
    while (i < BMP_I_LIMIT) : (j += 1) {
        var idx3 = self.index[i];
        fast_index[j] = @intCast(idx3);
        if (idx3 == self.data_null_offset.?) {
            if (idx3_first_null == null) {
                idx3_first_null = j;
            } else if (self.index3_null_offset == null and
                (j - idx3_first_null.? + 1) == INDEX_3_BLOCK_LEN)
            {
                self.index3_null_offset = idx3_first_null.?;
            }
        } else {
            idx3_first_null = null;
        }

        const i_next = i + SMALL_DATA_BLOCKS_PER_BMP_BLOCK;
        i += 1;
        while (i < i_next) : (i += 1) {
            idx3 += SMALL_DATA_BLOCK_LEN;
            self.index[i] = idx3;
        }
    }

    try mixed_blocks.reset(fast_index_len, INDEX_3_BLOCK_LEN);
    try mixed_blocks.extend(u16, &fast_index, 0, 0, fast_index_len);

    var idx3_capacity: u32 = 0;
    idx3_first_null = self.index3_null_offset;
    var has_long_idx3_blocks = false;
    i = BMP_I_LIMIT;
    const i_limit = self.high_start >> SHIFT_3;
    while (i < i_limit) {
        j = i;
        const j_limit = i + INDEX_3_BLOCK_LEN;
        var oredIdx3: u32 = 0;
        var is_null = true;
        while (true) {
            const idx3 = self.index[j];
            oredIdx3 |= idx3;
            if (idx3 != self.data_null_offset.?) {
                is_null = false;
            }
            j += 1;
            if (j < j_limit) continue else break;
        }

        if (is_null) {
            self.flags[i] = I3_NULL;
            if (idx3_first_null == null) {
                if (oredIdx3 <= 0xFFFF) {
                    idx3_capacity += INDEX_3_BLOCK_LEN;
                } else {
                    idx3_capacity += INDEX_3_18BIT_BLOCK_LEN;
                    has_long_idx3_blocks = true;
                }
                idx3_first_null = 0;
            }
        } else {
            if (oredIdx3 <= 0xFFFF) {
                if (mixed_blocks.findBlock(u16, u32, &fast_index, self.index[i..])) |n| {
                    self.flags[i] = I3_BMP;
                    self.index[i] = n;
                } else {
                    self.flags[i] = I3_16;
                    idx3_capacity += INDEX_3_BLOCK_LEN;
                }
            } else {
                self.flags[i] = I3_18;
                idx3_capacity += INDEX_3_18BIT_BLOCK_LEN;
                has_long_idx3_blocks = true;
            }
        }
        i = j;
    }

    const idx2_capacity = (i_limit - BMP_I_LIMIT) >> SHIFT_2_3;
    const idx1_len = (idx2_capacity + INDEX_2_MASK) >> SHIFT_1_2;
    const idx16_capacity = fast_index_len + idx1_len + idx3_capacity + idx2_capacity + 1;
    self.index16 = try self.allocator.alloc(u16, idx16_capacity);
    @memcpy(self.index16[0..fast_index_len], fast_index[0..fast_index_len]);
    @memset(self.index16[fast_index_len..], 0);

    try mixed_blocks.reset(idx16_capacity, INDEX_3_BLOCK_LEN);
    var long_i3_blocks: MixedBlocks = undefined;
    if (has_long_idx3_blocks) {
        long_i3_blocks = MixedBlocks.init(self.allocator);
        try long_i3_blocks.reset(idx16_capacity, INDEX_3_18BIT_BLOCK_LEN);
    }
    defer if (has_long_idx3_blocks) {
        long_i3_blocks.deinit();
    };

    var index2: [UNICODE_LIMIT >> SHIFT_2]u16 = undefined;
    var idx2_len: u32 = 0;
    idx3_first_null = self.index3_null_offset;
    var idx3_start = fast_index_len + idx1_len;
    var index_len = idx3_start;

    i = BMP_I_LIMIT;
    while (i < i_limit) : (i += INDEX_3_BLOCK_LEN) {
        var idx3: ?u32 = null;
        var f = self.flags[i];
        if (f == I3_NULL and idx3_first_null == null) {
            f = if (self.data_null_offset.? <= 0xFFFF) I3_16 else I3_18;
            idx3_first_null = 0;
        }

        if (f == I3_NULL) {
            idx3 = self.index3_null_offset;
        } else if (f == I3_BMP) {
            idx3 = self.index[i];
        } else if (f == I3_16) {
            if (mixed_blocks.findBlock(u16, u32, self.index16, self.index[i..])) |n| {
                idx3 = n;
            } else {
                var n = if (index_len == idx3_start)
                    0
                else
                    getOverlap(u16, u32, self.index16, index_len, self.index[i..], INDEX_3_BLOCK_LEN);

                idx3 = index_len - n;
                const prev_index_len = index_len;
                while (n < INDEX_3_BLOCK_LEN) {
                    self.index16[index_len] = @intCast(self.index[i + n]);
                    index_len += 1;
                    n += 1;
                }
                try mixed_blocks.extend(u16, self.index16, idx3_start, prev_index_len, index_len);
                if (has_long_idx3_blocks) {
                    try long_i3_blocks.extend(u16, self.index16, idx3_start, prev_index_len, index_len);
                }
            }
        } else {
            std.debug.assert(f == I3_18);
            std.debug.assert(has_long_idx3_blocks);

            j = i;
            const j_limit = i + INDEX_3_BLOCK_LEN;
            var k = index_len;
            while (true) {
                k += 1;
                var v = self.index[j];
                j += 1;
                const mask = 0x30000;
                var upper_bits = (v & mask) >> 2;

                for (0..7) |shift| {
                    self.index16[k] = @intCast(v);
                    k += 1;
                    v = self.index[j];
                    j += 1;
                    upper_bits |= (v & mask) >> @intCast(4 + (shift * 2));
                }
                self.index16[k] = @intCast(v);
                k += 1;
                self.index16[k - 9] = @intCast(upper_bits);

                if (j < j_limit) continue else break;
            }

            if (long_i3_blocks.findBlock(u16, u16, self.index16, self.index16[index_len..])) |n| {
                idx3 = n | 0x8000;
            } else {
                var n = if (index_len == idx3_start)
                    0
                else
                    getOverlap(u16, u16, self.index16, index_len, self.index16[index_len..], INDEX_3_18BIT_BLOCK_LEN);
                idx3 = (index_len - n) | 0x8000;

                const prev_index_len = index_len;

                if (n > 0) {
                    const start = index_len;
                    while (n < INDEX_3_18BIT_BLOCK_LEN) {
                        self.index16[index_len] = self.index16[start + n];
                        index_len += 1;
                        n += 1;
                    }
                } else {
                    index_len += INDEX_3_18BIT_BLOCK_LEN;
                }
                try mixed_blocks.extend(u16, self.index16, idx3_start, prev_index_len, index_len);
                try long_i3_blocks.extend(u16, self.index16, idx3_start, prev_index_len, index_len);
            }
        }

        if (self.index3_null_offset == null and idx3_first_null != null) {
            self.index3_null_offset = idx3;
        }
        index2[idx2_len] = @intCast(idx3.?);
        idx2_len += 1;
    }

    std.debug.assert(idx2_len == idx2_capacity);
    std.debug.assert(index_len <= idx3_start + idx3_capacity);

    if (self.index3_null_offset == null) {
        self.index3_null_offset = NO_INDEX3_NULL_OFFSET;
    }

    if (index_len >= (NO_INDEX3_NULL_OFFSET + INDEX_3_BLOCK_LEN)) {
        return error.IndexOutOfBounds;
    }

    var block_len = INDEX_2_BLOCK_LEN;
    var idx1 = fast_index_len;
    i = 0;
    while (i < idx2_len) : (i += block_len) {
        var n: ?u32 = undefined;
        if ((idx2_len - 1) >= block_len) {
            std.debug.assert(block_len == INDEX_2_BLOCK_LEN);
            n = mixed_blocks.findBlock(u16, u16, self.index16, index2[i..]);
        } else {
            block_len = idx2_len - i;
            n = findSameBlock(self.index16, idx3_start, index_len, index2[i..], block_len);
        }

        var idx2: u32 = undefined;
        if (n) |nn| {
            idx2 = nn;
        } else {
            var nn = if (index_len == idx3_start)
                0
            else
                getOverlap(u16, u16, self.index16, index_len, index2[i..], block_len);
            idx2 = index_len - nn;

            const prev_index_len = index_len;
            while (nn < block_len) {
                self.index16[index_len] = index2[i + nn];
                index_len += 1;
                nn += 1;
            }
            try mixed_blocks.extend(u16, self.index16, idx3_start, prev_index_len, index_len);
        }
        self.index16[idx1] = @intCast(idx2);
        idx1 += 1;
    }

    std.debug.assert(idx1 == idx3_start);
    std.debug.assert(index_len <= idx16_capacity);

    return index_len;
}

fn getOverlap(comptime IntA: type, comptime IntB: type, p: []const IntA, p_len: u32, q: []const IntB, block_len: u32) u32 {
    var overlap = block_len - 1;
    std.debug.assert(overlap <= p_len);
    while (overlap > 0) {
        const ps = p[p_len - overlap ..][0..overlap];
        const qs = q[0..overlap];
        for (ps, qs) |psv, qsv| {
            if (psv != qsv) {
                break;
            }
        } else {
            break;
        }
        overlap -= 1;
    }
    return overlap;
}

fn findSameBlock(p: []const u16, p_start: u32, len: u32, q: []const u16, block_len: u32) ?u32 {
    const end = len - block_len;
    var start = p_start;
    while (start <= end) : (start += 1) {
        if (std.mem.eql(u16, p[start..][0..block_len], q)) {
            return start;
        }
    }
    return null;
}

const AllSameBlocks = struct {
    len: u32 = 0,
    most_recent: ?u32 = null,
    indexes: [capacity]u32 = [_]u32{0} ** capacity,
    values: [capacity]u32 = [_]u32{0} ** capacity,
    ref_counts: [capacity]u32 = [_]u32{0} ** capacity,

    const capacity = 32;

    fn findOrAdd(self: *AllSameBlocks, index: u32, count: u32, value: u32) union(enum) {
        Found: u32,
        Added,
        Overflow,
    } {
        if (self.most_recent) |most_recent| {
            if (self.values[most_recent] == value) {
                self.ref_counts[most_recent] += count;
                return .{ .Found = self.indexes[most_recent] };
            }
        }

        for (0..self.len) |i| {
            if (self.values[i] == value) {
                self.most_recent = @intCast(i);
                self.ref_counts[i] += count;
                return .{ .Found = self.indexes[i] };
            }
        }

        if (self.len == capacity) {
            return .Overflow;
        }

        const i = self.len;
        self.len += 1;
        self.most_recent = i;
        self.indexes[i] = index;
        self.values[i] = value;
        self.ref_counts[i] = count;
        return .Added;
    }

    fn add(self: *AllSameBlocks, index: u32, count: u32, value: u32) void {
        std.debug.assert(self.len == capacity);
        var least: ?u32 = null;
        var least_count: u32 = I_LIMIT;
        for (0..self.len) |i| {
            std.debug.assert(self.values[i] != value);
            if (self.ref_counts[i] < least_count) {
                least = @intCast(i);
                least_count = self.ref_counts[i];
            }
        }
        const i = least.?;
        self.most_recent = i;
        self.indexes[i] = index;
        self.values[i] = value;
        self.ref_counts[i] = count;
    }

    fn findMostUsed(self: *AllSameBlocks) ?u32 {
        if (self.len == 0) {
            return null;
        }

        var max: ?u32 = null;
        var max_count: u32 = 0;
        for (0..self.len) |i| {
            if (self.ref_counts[i] > max_count) {
                max = @intCast(i);
                max_count = self.ref_counts[i];
            }
        }
        return self.indexes[max.?];
    }
};

const MixedBlocks = struct {
    entries: std.AutoHashMap(u32, void),
    block_len: u32,

    fn init(allocator: std.mem.Allocator) MixedBlocks {
        return MixedBlocks{
            .entries = std.AutoHashMap(u32, void).init(allocator),
            .block_len = 0,
        };
    }

    fn deinit(self: *MixedBlocks) void {
        self.entries.deinit();
    }

    fn reset(self: *MixedBlocks, capacity: u32, block_len: u32) !void {
        self.entries.clearRetainingCapacity();
        try self.entries.ensureTotalCapacity(capacity);
        self.block_len = block_len;
    }

    fn extend(
        self: *MixedBlocks,
        comptime Int: type,
        data: []const Int,
        min_start: u32,
        prev_data_len: u32,
        new_data_len: u32,
    ) !void {
        var start = @as(i32, @intCast(prev_data_len)) - @as(i32, @intCast(self.block_len));
        if (start >= min_start) {
            start += 1;
        } else {
            start = @intCast(min_start);
        }

        const end = new_data_len - self.block_len;
        while (start <= end) : (start += 1) {
            const i: u32 = @intCast(start);
            const gop = try self.entries.getOrPutAdapted(data[i..], BlockContext(Int, Int){
                .data = data,
                .block_len = self.block_len,
            });
            gop.key_ptr.* = i;
        }
    }

    fn findBlock(self: *MixedBlocks, comptime IntA: type, comptime IntB: type, data: []const IntA, block: []const IntB) ?u32 {
        return self.entries.getKeyAdapted(block, BlockContext(IntA, IntB){
            .data = data,
            .block_len = self.block_len,
        });
    }

    fn findBlockValue(self: *MixedBlocks, data: []const u32, value: u32) ?u32 {
        return self.entries.getKeyAdapted(value, ValueContext{
            .data = data,
            .block_len = self.block_len,
        });
    }

    fn BlockContext(comptime IntA: type, comptime IntB: type) type {
        return struct {
            data: []const IntA,
            block_len: u32,

            pub fn hash(ctx: @This(), block: []const IntB) u64 {
                var hasher = std.hash.Wyhash.init(0);
                for (block[0..ctx.block_len]) |value| {
                    const bytes: [@sizeOf(IntB)]u8 = @bitCast(value);
                    hasher.update(&bytes);
                }
                return hasher.final();
            }

            pub fn eql(ctx: @This(), block: []const IntB, key: u32) bool {
                const data = ctx.data[key..];
                for (0..ctx.block_len) |i| {
                    if (data[i] != block[i]) {
                        return false;
                    }
                }
                return true;
            }
        };
    }

    const ValueContext = struct {
        data: []const u32,
        block_len: u32,

        pub fn hash(ctx: ValueContext, value: u32) u64 {
            const bytes: [4]u8 = @bitCast(value);
            var hasher = std.hash.Wyhash.init(0);
            for (0..ctx.block_len) |_| {
                hasher.update(&bytes);
            }
            return hasher.final();
        }

        pub fn eql(ctx: ValueContext, value: u32, key: u32) bool {
            const data = ctx.data[key..];
            for (0..ctx.block_len) |i| {
                if (data[i] != value) {
                    return false;
                }
            }
            return true;
        }
    };
};

const FAST_SHIFT: u32 = 6;
const FAST_DATA_BLOCK_LEN: u32 = 1 << FAST_SHIFT;
const FAST_DATA_MASK: u32 = FAST_DATA_BLOCK_LEN - 1;

const SHIFT_3: u32 = 4;
const SHIFT_2: u32 = 5 + SHIFT_3;
const SHIFT_1: u32 = 5 + SHIFT_2;

const SHIFT_2_3: u32 = SHIFT_2 - SHIFT_3;
const SHIFT_1_2: u32 = SHIFT_1 - SHIFT_2;

const INDEX_2_BLOCK_LEN: u32 = 1 << SHIFT_1_2;
const INDEX_2_MASK: u32 = INDEX_2_BLOCK_LEN - 1;
const CP_PER_INDEX_2_ENTRY: u32 = 1 << SHIFT_2;

const INDEX_3_BLOCK_LEN: u32 = 1 << SHIFT_2_3;
const INDEX_3_MASK: u32 = INDEX_3_BLOCK_LEN - 1;

const SMALL_DATA_BLOCK_LEN: u32 = 1 << SHIFT_3;
const SMALL_DATA_MASK: u32 = SMALL_DATA_BLOCK_LEN - 1;

const NO_INDEX3_NULL_OFFSET: u32 = 0x7FFF;
const NO_DATA_NULL_OFFSET: u32 = 0xFFFFF;
const BMP_INDEX_LEN: u32 = 0x10000 >> FAST_SHIFT;

const MAX_UNICODE: u32 = 0x10FFFF;

const UNICODE_LIMIT: u32 = 0x110000;
const BMP_LIMIT: u32 = 0x10000;
const ASCII_LIMIT: u32 = 0x80;

const I_LIMIT: u32 = UNICODE_LIMIT >> SHIFT_3;
const BMP_I_LIMIT: u32 = BMP_LIMIT >> SHIFT_3;
const ASCII_I_LIMIT: u32 = ASCII_LIMIT >> SHIFT_3;

const SMALL_DATA_BLOCKS_PER_BMP_BLOCK: u32 = 1 << (FAST_SHIFT - SHIFT_3);
const INDEX_3_18BIT_BLOCK_LEN: u32 = INDEX_3_BLOCK_LEN + (INDEX_3_BLOCK_LEN / 8);

const INITIAL_DATA_LEN: u32 = 1 << 14;
const MEDIUM_DATA_LEN: u32 = 1 << 17;
const MAX_DATA_LEN: u32 = UNICODE_LIMIT;

const FLAGS_LEN = UNICODE_LIMIT >> SHIFT_3;

const ALL_SAME = 0;
const MIXED = 1;
const SAME_AS = 2;

const I3_NULL = 0;
const I3_BMP = 1;
const I3_16 = 2;
const I3_18 = 3;
