const std = @import("std");
const ucd = @import("ucd.zig");
const BidiBrackets = @import("ucd/BidiBrackets.zig");
const BidiCategory = @import("ucd/BidiCategory.zig");
const DerivedBidi = @import("ucd/DerivedBidi.zig");

pub const BidiCat = BidiCategory.Value;

pub fn charCat(c: u32) BidiCat {
    return switch (ucd.trieValue(BidiCategory, c)) {
        .Any => switch (ucd.trieValue(DerivedBidi, c)) {
            .L => .L,
            .R => .R,
            .EN => .EN,
            .ES => .ES,
            .ET => .ET,
            .AN => .AN,
            .CS => .CS,
            .B => .B,
            .S => .S,
            .WS => .WS,
            .ON => .ON,
            .BN => .BN,
            .NSM => .NSM,
            .AL => .AL,
            .LRO => .LRO,
            .RLO => .RLO,
            .LRE => .LRE,
            .RLE => .RLE,
            .PDF => .PDF,
            .LRI => .LRI,
            .RLI => .RLI,
            .FSI => .FSI,
            .PDI => .PDI,
            .Any => .Any,
            .Error => .Error,
        },
        else => |cat| cat,
    };
}

pub fn charCats(allocator: std.mem.Allocator, chars: []const u32) ![]const BidiCat {
    const cats = try allocator.alloc(BidiCat, chars.len);
    for (chars, 0..) |c, i| {
        cats[i] = charCat(c);
    }
    return cats;
}

pub const Level = u8;

pub const ParagraphIterator = struct {
    cats: []const BidiCat,
    i: usize,

    pub fn init(cats: []const BidiCat) ParagraphIterator {
        return ParagraphIterator{
            .cats = cats,
            .i = 0,
        };
    }

    pub fn hasNext(self: *ParagraphIterator) bool {
        return self.i < self.cats.len;
    }

    pub fn next(self: *ParagraphIterator) Level {
        std.debug.assert(self.hasNext());

        var isolate_count: usize = 0;
        var level: ?u8 = null;

        for (self.cats) |cat| {
            self.i += 1;
            switch (cat) {
                .B => break,
                .LRI, .RLI, .FSI => isolate_count += 1,
                .PDI => if (isolate_count > 0) {
                    isolate_count -= 1;
                },
                .L => if (level == null and isolate_count == 0) {
                    level = 0;
                },
                .R, .AL => if (level == null and isolate_count == 0) {
                    level = 1;
                },
                else => {},
            }
        }

        return level orelse 0;
    }
};

pub fn reorder(
    allocator: std.mem.Allocator,
    cats: []const BidiCat,
    levels: []Level,
    paragraph_level: Level,
) ![]const usize {
    std.debug.assert(cats.len > 0);
    std.debug.assert(cats.len == levels.len);
    var seq_start: ?usize = null;
    for (cats, 0..) |cat, i| {
        if (ignoreCat(cat)) {
            continue;
        }

        switch (cat) {
            .B, .S => {
                levels[i] = paragraph_level;
                if (seq_start) |ss| {
                    @memset(levels[ss..i], paragraph_level);
                }
            },
            .WS, .RLI, .LRI, .FSI, .PDI => {
                if (seq_start == null) {
                    seq_start = i;
                }
            },
            else => {
                seq_start = null;
            },
        }
    }
    if (seq_start) |ss| {
        @memset(levels[ss..], paragraph_level);
    }

    var min_level = levels[0];
    var max_level = min_level;
    var prev_level = min_level;
    for (0..levels.len) |i| {
        if (ignoreCat(cats[i])) {
            continue;
        }
        const level = levels[i];
        if (level != prev_level) {
            min_level = @min(min_level, level);
            max_level = @max(max_level, level);
            prev_level = level;
        }
    }

    var order = std.ArrayList(usize).init(allocator);
    for (cats, 0..) |cat, index| {
        if (ignoreCat(cat)) {
            continue;
        }
        try order.append(index);
    }

    min_level = if (min_level % 2 == 1) min_level else min_level + 1;

    var level = max_level;
    while (level >= min_level) : (level -= 1) {
        var index: usize = 0;
        var level_start: ?usize = null;
        for (cats, 0..) |cat, i| {
            if (ignoreCat(cat)) {
                continue;
            }

            if (levels[i] >= level) {
                if (level_start == null) {
                    level_start = index;
                }
            } else if (level_start) |start| {
                std.mem.reverse(usize, order.items[start..index]);
                level_start = null;
            }
            index += 1;
        }
        if (level_start) |start| {
            std.mem.reverse(usize, order.items[start..]);
        }
    }

    return order.toOwnedSlice();
}

pub fn resolve(
    allocator: std.mem.Allocator,
    chars: []const u32,
    char_cats: []const BidiCat,
    paragraph_level: Level,
) ![]Level {
    const levels = try allocator.alloc(Level, chars.len);
    @memset(levels, 0);

    const cats = try allocator.alloc(BidiCat, chars.len);
    defer allocator.free(cats);

    resolveExplicitTypes(char_cats, levels, cats, paragraph_level);

    const sequences = try resolveSequences(allocator, levels, cats, paragraph_level);
    defer freeSequences(allocator, sequences);

    resolveWeakTypes(char_cats, cats, sequences);
    try resolveNeutralTypes(allocator, chars, char_cats, cats, sequences);
    resolveImplicitLevels(levels, cats, sequences);

    return levels;
}

fn resolveExplicitTypes(
    char_cats: []const BidiCat,
    levels: []Level,
    cats: []BidiCat,
    paragraph_level: Level,
) void {
    var state: struct {
        levels: []Level,
        cats: []BidiCat,
        stack: [stack_size]DirectionalStatus = undefined,
        stack_len: usize = 0,
        overflow_isolate: usize = 0,
        overflow_embedding: usize = 0,
        valid_isolate: usize = 0,

        const max_depth = 125;
        const stack_size = max_depth + 2;

        const DirectionalStatus = struct {
            level: Level,
            override: ?BidiCat,
            isolate: bool,
        };

        fn pushEmbedding(self: *@This(), level: Level, override: ?BidiCat, i: usize) void {
            if (level <= max_depth and self.overflow_isolate == 0 and self.overflow_embedding == 0) {
                self.push(.{
                    .level = level,
                    .override = override,
                    .isolate = false,
                });
                self.levels[i] = level;
            } else if (self.overflow_isolate == 0) {
                self.overflow_embedding += 1;
            }
        }

        fn pushRLI(self: *@This(), i: usize) void {
            self.set(i, .RLI);
            self.pushIsolate(self.nextOddLevel());
        }

        fn pushLRI(self: *@This(), i: usize) void {
            self.set(i, .LRI);
            self.pushIsolate(self.nextEvenLevel());
        }

        fn pushIsolate(self: *@This(), level: u8) void {
            if (level <= max_depth and self.overflow_isolate == 0 and self.overflow_embedding == 0) {
                self.valid_isolate += 1;
                self.push(.{
                    .level = level,
                    .override = null,
                    .isolate = true,
                });
            } else {
                self.overflow_isolate += 1;
            }
        }

        fn set(self: *@This(), i: usize, cat: BidiCat) void {
            const last = self.lastEntry();
            self.levels[i] = last.level;
            self.cats[i] = last.override orelse cat;
        }

        inline fn push(self: *@This(), entry: DirectionalStatus) void {
            self.stack[self.stack_len] = entry;
            self.stack_len += 1;
        }

        fn pop(self: *@This()) DirectionalStatus {
            const last = self.lastEntry();
            self.stack_len -= 1;
            return last;
        }

        fn nextOddLevel(self: *const @This()) Level {
            const level = self.lastLevel() + 1;
            if (level % 2 == 0) {
                return level + 1;
            }
            return level;
        }

        fn nextEvenLevel(self: *const @This()) Level {
            const level = self.lastLevel() + 1;
            if (level % 2 == 1) {
                return level + 1;
            }
            return level;
        }

        fn lastLevel(self: *const @This()) Level {
            return self.lastEntry().level;
        }

        fn lastEntry(self: *const @This()) DirectionalStatus {
            return self.stack[self.stack_len - 1];
        }
    } = .{ .levels = levels, .cats = cats };

    state.push(.{
        .level = paragraph_level,
        .override = null,
        .isolate = false,
    });

    for (char_cats, 0..) |cat, i| {
        switch (cat) {
            .RLE => {
                state.pushEmbedding(state.nextOddLevel(), null, i);
                cats[i] = .RLE;
            },
            .LRE => {
                state.pushEmbedding(state.nextEvenLevel(), null, i);
                cats[i] = .LRE;
            },
            .RLO => {
                state.pushEmbedding(state.nextOddLevel(), .R, i);
                cats[i] = .RLO;
            },
            .LRO => {
                state.pushEmbedding(state.nextEvenLevel(), .L, i);
                cats[i] = .LRO;
            },
            .PDF => {
                if (state.overflow_isolate > 0) {
                    // do nothing
                } else if (state.overflow_embedding > 0) {
                    state.overflow_embedding -= 1;
                } else {
                    const last = state.lastEntry();
                    if (!last.isolate and state.stack_len >= 2) {
                        _ = state.pop();
                    }
                }
                levels[i] = state.lastEntry().level;
                cats[i] = .PDF;
            },
            .RLI => state.pushRLI(i),
            .LRI => state.pushLRI(i),
            .FSI => {
                var isolate_count: usize = 0;
                for (char_cats[(i + 1)..]) |next_cat| {
                    switch (next_cat) {
                        .RLI, .LRI, .FSI => {
                            isolate_count += 1;
                        },
                        .PDI => {
                            if (isolate_count > 0) {
                                isolate_count -= 1;
                            } else {
                                state.pushLRI(i);
                                break;
                            }
                        },
                        .L => if (isolate_count == 0) {
                            state.pushLRI(i);
                            break;
                        },
                        .R, .AL => if (isolate_count == 0) {
                            state.pushRLI(i);
                            break;
                        },
                        else => {},
                    }
                } else {
                    state.pushLRI(i);
                }
            },
            .PDI => {
                if (state.overflow_isolate > 0) {
                    state.overflow_isolate -= 1;
                } else if (state.valid_isolate > 0) {
                    state.overflow_embedding = 0;
                    while (true) {
                        const popped = state.pop();
                        if (popped.isolate) {
                            break;
                        }
                    }
                    state.valid_isolate -= 1;
                }
                state.set(i, .PDI);
            },
            .B, .BN => {
                levels[i] = paragraph_level;
                cats[i] = cat;
            },
            else => state.set(i, cat),
        }
    }
}

fn resolveSequences(
    allocator: std.mem.Allocator,
    levels: []const Level,
    cats: []const BidiCat,
    paragraph_level: Level,
) ![]const Sequence {
    const SequenceLevelRuns = std.ArrayList(LevelRun);

    var seqs_runs = std.ArrayList(SequenceLevelRuns).init(allocator);
    defer {
        for (seqs_runs.items) |slr| {
            slr.deinit();
        }
        seqs_runs.deinit();
    }

    var stack = std.ArrayList(SequenceLevelRuns).init(allocator);
    defer stack.deinit();

    var iter = LevelRunIterator{ .levels = levels, .cats = cats };
    while (iter.next()) |run| {
        const start_cat = cats[run.start];
        const end_cat = cats[run.end - 1];

        var seq = if (start_cat == .PDI and stack.items.len > 0)
            stack.pop()
        else
            SequenceLevelRuns.init(allocator);

        try seq.append(run);

        switch (end_cat) {
            .RLI, .LRI, .FSI => {
                try stack.append(seq);
            },
            else => {
                try seqs_runs.append(seq);
            },
        }
    }

    while (stack.popOrNull()) |seq| {
        try seqs_runs.append(seq);
    }

    var seqs = std.ArrayList(Sequence).init(allocator);
    for (seqs_runs.items) |seq_runs| {
        const seq_start = seq_runs.items[0].start;
        const seq_end = seq_runs.getLast().end;

        const sos_level = blk: {
            var sos_level = paragraph_level;
            if (seq_start != 0) {
                var i = seq_start - 1;
                while (i > 0) : (i -= 1) {
                    if (ignoreCat(cats[i])) {
                        continue;
                    }

                    sos_level = levels[i];
                    break;
                }
            }

            break :blk @max(sos_level, levels[seq_start]);
        };
        const sos: BidiCat = if (sos_level % 2 == 0) .L else .R;

        const eos_level = blk: {
            var eos_level: Level = paragraph_level;
            switch (cats[seq_end - 1]) {
                .RLI, .LRI, .FSI => {
                    // if the sequence ends with an isolate initiator we compare with the paragraph level.
                },
                else => {
                    // else compare with the next non-ignored character in the whole paragraph text.
                    var i = seq_end;
                    while (i < levels.len) : (i += 1) {
                        if (ignoreCat(cats[i])) {
                            continue;
                        }

                        eos_level = levels[i];
                        break;
                    }
                },
            }

            break :blk @max(eos_level, levels[seq_end - 1]);
        };
        const eos: BidiCat = if (eos_level % 2 == 0) .L else .R;

        var runs = try std.ArrayList(LevelRun).initCapacity(allocator, seq_runs.items.len);
        for (seq_runs.items) |run| {
            try runs.append(run);
        }

        try seqs.append(Sequence{
            .level = seq_runs.items[0].level,
            .runs = try runs.toOwnedSlice(),
            .sos = sos,
            .eos = eos,
        });
    }

    return try seqs.toOwnedSlice();
}

fn freeSequences(allocator: std.mem.Allocator, sequences: []const Sequence) void {
    for (sequences) |seq| {
        allocator.free(seq.runs);
    }
    allocator.free(sequences);
}

fn resolveWeakTypes(char_cats: []const BidiCat, cats: []BidiCat, sequences: []const Sequence) void {
    var state: struct {
        char_cats: []const BidiCat,
        cats: []BidiCat,
        seq: Sequence,
        strong_type: BidiCat,
        et_seq_start: ?Sequence.Pos = null,

        fn next(self: *@This(), cat: BidiCat, pos: Sequence.Pos) void {
            var reset_et_seq_start = true;
            switch (cat) {
                .NSM => {
                    var p_cat: ?BidiCat = null;
                    var p_pos = pos;
                    while (p_pos.prev(self.seq, self.cats)) |p| {
                        const c = self.char_cats[p.ii];
                        if (c != .NSM) {
                            p_cat = c;
                            break;
                        }

                        p_pos = p;
                    }
                    if (p_cat) |c| {
                        switch (c) {
                            .RLI, .LRI, .FSI, .PDI => {
                                self.cats[pos.ii] = .ON;
                            },
                            else => {
                                self.cats[pos.ii] = c;
                                self.next(c, pos);
                                // this will have been handled by the call above
                                reset_et_seq_start = false;
                            },
                        }
                    } else {
                        self.cats[pos.ii] = self.seq.sos;
                        self.strong_type = self.seq.sos;
                    }
                },
                .R, .L => {
                    self.strong_type = cat;
                },
                .AL => {
                    self.strong_type = .AL;
                    self.cats[pos.ii] = .R;
                },
                .EN => {
                    if (self.strong_type == .AL) {
                        self.cats[pos.ii] = .AN;
                        self.checkCSBetweenAN(pos);
                    } else {
                        if (pos.prev(self.seq, self.cats)) |p| {
                            const p_cat = self.char_cats[p.ii];
                            if (p_cat == .CS or p_cat == .ES) {
                                if (p.prev(self.seq, self.cats)) |pp| {
                                    if (self.treatAsEn(pp, false)) {
                                        self.cats[p.ii] = if (self.strong_type == .L) .L else .EN;
                                    }
                                }
                            }
                        }

                        if (self.et_seq_start) |ess| {
                            for (ess.ri..(pos.ri + 1)) |ri| {
                                const start = if (ri == ess.ri) ess.ii else self.seq.runs[ri].start;
                                const end = if (ri == pos.ri) pos.ii else self.seq.runs[ri].end;
                                for (start..end) |ci| {
                                    if (ignoreCat(self.cats[ci])) {
                                        continue;
                                    }

                                    self.cats[ci] = if (self.strong_type == .L) .L else .EN;
                                }
                            }
                        }

                        if (self.strong_type == .L) {
                            self.cats[pos.ii] = .L;
                        }
                    }
                },
                .AN => {
                    self.checkCSBetweenAN(pos);
                },
                .ET => {
                    self.cats[pos.ii] = .ON;
                    const p = pos.prev(self.seq, self.cats);
                    if (p != null and self.treatAsEn(p.?, true)) {
                        self.cats[pos.ii] = if (self.strong_type == .L) .L else .EN;
                    } else {
                        if (self.et_seq_start == null) {
                            self.et_seq_start = pos;
                        }
                        reset_et_seq_start = false;
                    }
                },
                .ES, .CS => {
                    self.cats[pos.ii] = .ON;
                },
                else => {
                    // do nothing
                },
            }
            if (reset_et_seq_start) {
                self.et_seq_start = null;
            }
        }

        fn checkCSBetweenAN(self: @This(), pos: Sequence.Pos) void {
            if (pos.prev(self.seq, self.cats)) |p| {
                if (self.char_cats[p.ii] == .CS) {
                    if (p.prev(self.seq, self.cats)) |pp| {
                        if (self.cats[pp.ii] == .AN) {
                            self.cats[p.ii] = .AN;
                        }
                    }
                }
            }
        }

        fn treatAsEn(self: @This(), pos: Sequence.Pos, include_et: bool) bool {
            return switch (self.cats[pos.ii]) {
                .EN => if (!include_et) self.char_cats[pos.ii] != .ET else true,
                .L => switch (self.char_cats[pos.ii]) {
                    .EN, .ET => true,
                    .NSM => if (pos.prev(self.seq, self.cats)) |p| self.char_cats[p.ii] == .EN else false,
                    else => false,
                },
                else => false,
            };
        }
    } = undefined;

    for (sequences) |seq| {
        state = .{ .char_cats = char_cats, .cats = cats, .seq = seq, .strong_type = seq.sos };
        for (seq.runs, 0..) |run, ri| {
            for (run.start..run.end) |ii| {
                const cat = cats[ii];
                if (ignoreCat(cat)) {
                    continue;
                }

                state.next(cat, Sequence.Pos{
                    .ri = ri,
                    .ii = ii,
                });
            }
        }
    }
}

fn resolveNeutralTypes(
    allocator: std.mem.Allocator,
    chars: []const u32,
    char_cats: []const BidiCat,
    cats: []BidiCat,
    sequences: []const Sequence,
) !void {
    for (sequences) |seq| {
        const e: BidiCat = if (seq.level % 2 == 0) .L else .R;

        const pairs = try resolveBracketPairs(allocator, chars, cats, seq);
        defer allocator.free(pairs);

        outer: for (pairs) |pair| {
            var strong_type: ?BidiCat = null;
            for (pair.opening.ri..(pair.closing.ri + 1)) |ri| {
                const start = if (ri == pair.opening.ri) pair.opening.ii else seq.runs[ri].start;
                const end = if (ri == pair.closing.ri) pair.closing.ii else seq.runs[ri].end;
                for (start..end) |ii| {
                    var cat = cats[ii];
                    if (ignoreCat(cat)) {
                        continue;
                    }

                    if (cat == .EN or cat == .AN) {
                        cat = .R;
                    }

                    if (cat == e) {
                        cats[pair.opening.ii] = e;
                        cats[pair.closing.ii] = e;
                        checkNSMAfterPairedBracket(seq, pair.opening, char_cats, cats, e);
                        checkNSMAfterPairedBracket(seq, pair.closing, char_cats, cats, e);
                        continue :outer;
                    }

                    if (cat == .L or cat == .R) {
                        strong_type = cat;
                    }
                }
            }

            if (strong_type == null) {
                continue;
            }

            var ri = pair.opening.ri + 1;
            var ii = pair.opening.ii;
            const context = ctx: while (ri > 0) : (ri -= 1) {
                while (ii > seq.runs[ri - 1].start) : (ii -= 1) {
                    switch (cats[ii - 1]) {
                        .L, .R => |cat| break :ctx cat,
                        .EN, .AN => break :ctx .R,
                        else => {},
                    }
                }

                if (ri - 1 > 0) {
                    ii = seq.runs[ri - 2].end;
                }
            } else seq.sos;

            const new_cat = if (context == strong_type.?) context else e;
            cats[pair.opening.ii] = new_cat;
            cats[pair.closing.ii] = new_cat;
            checkNSMAfterPairedBracket(seq, pair.opening, char_cats, cats, new_cat);
            checkNSMAfterPairedBracket(seq, pair.closing, char_cats, cats, new_cat);
        }

        var prev_char: ?usize = null;
        var ni_seq_ctx: ?BidiCat = null;
        var ni_seq_start: ?Sequence.Pos = null;
        for (seq.runs, 0..) |run, ri| {
            for (run.start..run.end) |ii| {
                const cat = cats[ii];
                if (ignoreCat(cat)) {
                    continue;
                }

                const prev = prev_char;
                prev_char = ii;

                switch (cat) {
                    .B, .S, .WS, .ON, .FSI, .LRI, .RLI, .PDI => {
                        cats[ii] = e;
                        if (ni_seq_start != null) {
                            continue;
                        }

                        if (prev) |p| {
                            switch (cats[p]) {
                                .L, .R => {
                                    ni_seq_ctx = cats[p];
                                },
                                .EN, .AN => {
                                    ni_seq_ctx = .R;
                                },
                                else => {
                                    continue;
                                },
                            }
                        } else {
                            ni_seq_ctx = seq.sos;
                        }
                        ni_seq_start = Sequence.Pos{
                            .ri = ri,
                            .ii = ii,
                        };
                    },
                    .L, .R, .AN, .EN => {
                        if (ni_seq_start) |start| {
                            const context = if (cat == .AN or cat == .EN) .R else cat;
                            if (ni_seq_ctx.? == context) {
                                setAllInSequence(seq, start, Sequence.Pos{ .ri = ri, .ii = ii }, cats, context);
                            }

                            ni_seq_ctx = null;
                            ni_seq_start = null;
                        }
                    },
                    else => {
                        ni_seq_ctx = null;
                        ni_seq_start = null;
                    },
                }
            }
        }

        if (ni_seq_start) |start| {
            if (ni_seq_ctx.? == seq.eos) {
                const end_ri = seq.runs.len - 1;
                const end_ii = seq.runs[end_ri].end;
                setAllInSequence(seq, start, Sequence.Pos{ .ri = end_ri, .ii = end_ii }, cats, seq.eos);
            }
        }
    }
}

fn checkNSMAfterPairedBracket(
    seq: Sequence,
    pos: Sequence.Pos,
    char_cats: []const BidiCat,
    cats: []BidiCat,
    cat: BidiCat,
) void {
    var ri = pos.ri;
    var ii = pos.ii + 1;
    outer: while (ri < seq.runs.len) : (ri += 1) {
        while (ii < seq.runs[ri].end) : (ii += 1) {
            const c = char_cats[ii];
            if (ignoreCat(c)) {
                continue;
            }

            switch (c) {
                .NSM => {
                    cats[ii] = cat;
                },
                else => break :outer,
            }
        }
    }
}

fn setAllInSequence(
    seq: Sequence,
    start: Sequence.Pos,
    end: Sequence.Pos,
    cats: []BidiCat,
    cat: BidiCat,
) void {
    for (start.ri..(end.ri + 1)) |ri| {
        const start_idx = if (ri == start.ri) start.ii else seq.runs[ri].start;
        const end_idx = if (ri == end.ri) end.ii else seq.runs[ri].end;
        for (start_idx..end_idx) |ii| {
            if (ignoreCat(cats[ii])) {
                continue;
            }
            cats[ii] = cat;
        }
    }
}

fn resolveBracketPairs(
    allocator: std.mem.Allocator,
    chars: []const u32,
    cats: []const BidiCat,
    seq: Sequence,
) ![]const BracketPair {
    var state: struct {
        stack: [stack_size]StackEntry = undefined,
        stack_len: usize = 0,
        pairs: std.ArrayList(BracketPair),

        const stack_size = 63;
        const StackEntry = struct {
            bracket: BidiBrackets.Bracket,
            pos: Sequence.Pos,
        };

        fn append(self: *@This(), opening: Sequence.Pos, ri: usize, ii: usize) !void {
            try self.pairs.append(BracketPair{
                .opening = opening,
                .closing = Sequence.Pos{
                    .ri = ri,
                    .ii = ii,
                },
            });
        }

        fn push(self: *@This(), bracket: BidiBrackets.Bracket, ri: usize, ii: usize) bool {
            if (self.stack_len >= stack_size) {
                return false;
            }
            self.stack[self.stack_len] = StackEntry{
                .bracket = bracket,
                .pos = Sequence.Pos{
                    .ri = ri,
                    .ii = ii,
                },
            };
            self.stack_len += 1;
            return true;
        }

        fn pop(self: *@This(), new_len: usize) void {
            self.stack_len = new_len;
        }
    } = .{ .pairs = std.ArrayList(BracketPair).init(allocator) };

    outer: for (seq.runs, 0..) |run, ri| {
        for (run.start..run.end) |ii| {
            const cat = cats[ii];
            if (ignoreCat(cat)) {
                continue;
            }

            // only .ON characters can be a paired bracket
            if (cat != .ON) {
                continue;
            }

            if (BidiBrackets.get(chars[ii])) |bracket| {
                switch (bracket.type) {
                    .opening => {
                        if (!state.push(bracket, ri, ii)) {
                            break :outer;
                        }
                    },
                    .closing => {
                        var i = state.stack_len;
                        while (i > 0) : (i -= 1) {
                            const entry = state.stack[i - 1];

                            var matches = entry.bracket.pair == chars[ii];
                            if (!matches) {
                                if (entry.bracket.mapping) |mapping| {
                                    if (BidiBrackets.get(mapping)) |mb| {
                                        matches = mb.pair == chars[ii];
                                    }
                                }
                            }

                            if (matches) {
                                try state.append(entry.pos, ri, ii);
                                state.pop(i - 1);
                                break;
                            }
                        }
                    },
                }
            }
        }
    }

    var pairs = try state.pairs.toOwnedSlice();
    std.mem.sort(
        BracketPair,
        pairs,
        @as(void, undefined),
        struct {
            fn lessThan(_: void, lhs: BracketPair, rhs: BracketPair) bool {
                return lhs.opening.ii < rhs.opening.ii;
            }
        }.lessThan,
    );
    return pairs;
}

const BracketPair = struct {
    opening: Sequence.Pos,
    closing: Sequence.Pos,
};

fn resolveImplicitLevels(levels: []Level, cats: []const BidiCat, sequences: []const Sequence) void {
    for (sequences) |seq| {
        for (seq.runs) |run| {
            for (run.start..run.end) |ii| {
                if (seq.level % 2 == 0) {
                    switch (cats[ii]) {
                        .R => {
                            levels[ii] += 1;
                        },
                        .AN, .EN => {
                            levels[ii] += 2;
                        },
                        else => {},
                    }
                } else {
                    switch (cats[ii]) {
                        .L, .EN, .AN => {
                            levels[ii] += 1;
                        },
                        else => {},
                    }
                }
            }
        }
    }
}

const Sequence = struct {
    level: Level,
    runs: []const LevelRun,
    sos: BidiCat,
    eos: BidiCat,

    const Pos = struct {
        ri: usize,
        ii: usize,

        fn prev(self: Pos, seq: Sequence, cats: []const BidiCat) ?Pos {
            var pos = self;
            while (pos.nextPrev(seq)) |p| {
                if (ignoreCat(cats[p.ii])) {
                    pos = p;
                    continue;
                }

                return p;
            }
            return null;
        }

        fn nextPrev(self: Pos, seq: Sequence) ?Pos {
            if (self.ii > seq.runs[self.ri].start) {
                return Pos{
                    .ri = self.ri,
                    .ii = self.ii - 1,
                };
            }

            if (self.ri > 0) {
                const new_ri = self.ri - 1;
                return Pos{
                    .ri = new_ri,
                    .ii = seq.runs[new_ri].end - 1,
                };
            }

            return null;
        }
    };
};

const LevelRunIterator = struct {
    levels: []const Level,
    cats: []const BidiCat,
    i: usize = 0,

    fn next(self: *LevelRunIterator) ?LevelRun {
        if (self.i >= self.levels.len) {
            return null;
        }

        var start = self.i;
        for (self.i..self.levels.len) |i| {
            if (ignoreCat(self.cats[i])) {
                start += 1;
            } else {
                break;
            }
        }

        if (start >= self.levels.len) {
            return null;
        }

        const level: u8 = self.levels[start];
        var end = start + 1;
        for (start..self.levels.len) |i| {
            if (ignoreCat(self.cats[i])) {
                continue;
            }

            if (self.levels[i] != level) {
                break;
            }

            end = i + 1;
        }

        self.i = end;

        return LevelRun{
            .level = level,
            .start = start,
            .end = end,
        };
    }
};

const LevelRun = struct {
    level: Level,
    start: usize,
    end: usize,
};

inline fn ignoreCat(cat: BidiCat) bool {
    return switch (cat) {
        .RLE, .LRE, .RLO, .LRO, .PDF, .BN => true,
        else => false,
    };
}

test "BidiTest" {
    const test_data = @embedFile("ucd/BidiTest.txt");
    const allocator = std.testing.allocator;

    var debug = DebugPrint{};

    var levels = std.ArrayList(?Level).init(allocator);
    defer levels.deinit();

    var order = std.ArrayList(usize).init(allocator);
    defer order.deinit();

    var chars = std.ArrayList(u32).init(allocator);
    defer chars.deinit();

    var lines = std.mem.splitScalar(u8, test_data, '\n');
    while (lines.next()) |line| : (debug.line += 1) {
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        if (line[0] == '@') {
            var info_split = std.mem.splitScalar(u8, line[1..], ':');
            const info_type = info_split.next().?;
            const info = std.mem.trim(u8, info_split.next().?, " \t");
            if (std.mem.eql(u8, info_type, "Levels")) {
                levels.clearRetainingCapacity();
                var levels_iter = std.mem.splitScalar(u8, info, ' ');
                while (levels_iter.next()) |level| {
                    if (level[0] == 'x') {
                        try levels.append(null);
                    } else {
                        try levels.append(try std.fmt.parseInt(u8, level, 10));
                    }
                }

                debug.levels = levels.items;
            } else if (std.mem.eql(u8, info_type, "Reorder")) {
                order.clearRetainingCapacity();
                var reordered_iter = std.mem.splitScalar(u8, info, ' ');
                while (reordered_iter.next()) |index| {
                    if (index.len == 0) {
                        continue;
                    }
                    try order.append(try std.fmt.parseInt(Level, index, 10));
                }

                debug.order = order.items;
            } else {
                return error.UnexpectedBidiTestInfoType;
            }
            continue;
        }

        var data_split = std.mem.splitScalar(u8, line, ';');
        const cats_data = std.mem.trim(u8, data_split.next().?, " \t");
        const paragraphs_data = std.mem.trim(u8, data_split.next().?, " \t");

        chars.clearRetainingCapacity();
        var cats_iter = std.mem.splitScalar(u8, cats_data, ' ');
        while (cats_iter.next()) |cat| {
            const char = catStrToChar(cat);
            try chars.append(char);
        }

        const cats = try charCats(allocator, chars.items);
        defer allocator.free(cats);

        debug.cats = cats;

        const auto: u8 = 1;
        const ltr: u8 = 2;
        const rtl: u8 = 4;
        const paragraphs = try std.fmt.parseInt(u8, paragraphs_data, 10);
        if (paragraphs & auto != 0) {
            expectLevelsAndReorder(
                findParagraphLevel(cats),
                chars.items,
                cats,
                levels.items,
                order.items,
            ) catch |e| {
                debug.print();
                return e;
            };
        }
        if (paragraphs & ltr != 0) {
            expectLevelsAndReorder(
                0,
                chars.items,
                cats,
                levels.items,
                order.items,
            ) catch |e| {
                debug.print();
                return e;
            };
        }
        if (paragraphs & rtl != 0) {
            expectLevelsAndReorder(
                1,
                chars.items,
                cats,
                levels.items,
                order.items,
            ) catch |e| {
                debug.print();
                return e;
            };
        }
    }
}

fn catStrToChar(cat: []const u8) u32 {
    return if (std.mem.eql(u8, cat, "AL"))
        '\u{060B}'
    else if (std.mem.eql(u8, cat, "AN"))
        '\u{0605}'
    else if (std.mem.eql(u8, cat, "B"))
        '\u{000A}'
    else if (std.mem.eql(u8, cat, "BN"))
        '\u{2060}'
    else if (std.mem.eql(u8, cat, "CS"))
        '\u{2044}'
    else if (std.mem.eql(u8, cat, "EN"))
        '\u{06F9}'
    else if (std.mem.eql(u8, cat, "ES"))
        '\u{208B}'
    else if (std.mem.eql(u8, cat, "ET"))
        '\u{20CF}'
    else if (std.mem.eql(u8, cat, "FSI"))
        '\u{2068}'
    else if (std.mem.eql(u8, cat, "L"))
        '\u{02B8}'
    else if (std.mem.eql(u8, cat, "LRE"))
        '\u{202A}'
    else if (std.mem.eql(u8, cat, "LRI"))
        '\u{2066}'
    else if (std.mem.eql(u8, cat, "LRO"))
        '\u{202D}'
    else if (std.mem.eql(u8, cat, "NSM"))
        '\u{0300}'
    else if (std.mem.eql(u8, cat, "ON"))
        '\u{03F6}'
    else if (std.mem.eql(u8, cat, "PDF"))
        '\u{202C}'
    else if (std.mem.eql(u8, cat, "PDI"))
        '\u{2069}'
    else if (std.mem.eql(u8, cat, "R"))
        '\u{0590}'
    else if (std.mem.eql(u8, cat, "RLE"))
        '\u{202B}'
    else if (std.mem.eql(u8, cat, "RLI"))
        '\u{2067}'
    else if (std.mem.eql(u8, cat, "RLO"))
        '\u{202E}'
    else if (std.mem.eql(u8, cat, "S"))
        '\u{001F}'
    else if (std.mem.eql(u8, cat, "WS"))
        '\u{200A}'
    else
        @panic("invalid cat str");
}

fn findParagraphLevel(cats: []const BidiCat) Level {
    var isolate_count: usize = 0;
    for (cats) |cat| {
        switch (cat) {
            .B => {
                break;
            },
            .LRI, .RLI, .FSI => {
                isolate_count += 1;
            },
            .PDI => if (isolate_count > 0) {
                isolate_count -= 1;
            },
            .L => if (isolate_count == 0) {
                return 0;
            },
            .R, .AL => if (isolate_count == 0) {
                return 1;
            },
            else => {},
        }
    }

    return 0;
}

test "BidiCharacterTest" {
    const test_data = @embedFile("ucd/BidiCharacterTest.txt");
    const allocator = std.testing.allocator;

    var debug = DebugPrint{};

    var chars = std.ArrayList(u32).init(allocator);
    defer chars.deinit();

    var levels = std.ArrayList(?Level).init(allocator);
    defer levels.deinit();

    var order = std.ArrayList(usize).init(allocator);
    defer order.deinit();

    var lines = std.mem.splitScalar(u8, test_data, '\n');
    while (lines.next()) |line| : (debug.line += 1) {
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        var data_split = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \t"), ';');

        const char_data = data_split.next().?;
        _ = data_split.next().?;
        const paragraph_level_data = data_split.next().?;
        const levels_data = data_split.next().?;
        const order_data = data_split.next().?;

        var chars_iter = std.mem.splitScalar(u8, char_data, ' ');
        while (chars_iter.next()) |char_str| {
            const char = try std.fmt.parseInt(u32, char_str, 16);
            try chars.append(char);
        }

        const cats = try charCats(allocator, chars.items);
        defer allocator.free(cats);

        const paragraph_level = try std.fmt.parseInt(Level, paragraph_level_data, 10);

        var levels_iter = std.mem.splitScalar(u8, levels_data, ' ');
        while (levels_iter.next()) |level| {
            if (level[0] == 'x') {
                try levels.append(null);
            } else {
                try levels.append(try std.fmt.parseInt(Level, level, 10));
            }
        }

        var order_iter = std.mem.splitScalar(u8, order_data, ' ');
        while (order_iter.next()) |idx| {
            if (idx.len == 0) {
                continue;
            }
            try order.append(try std.fmt.parseInt(usize, idx, 10));
        }

        debug.cats = cats;
        debug.levels = levels.items;
        debug.order = order.items;

        expectLevelsAndReorder(
            paragraph_level,
            chars.items,
            cats,
            levels.items,
            order.items,
        ) catch |e| {
            debug.print();
            return e;
        };

        chars.clearRetainingCapacity();
        levels.clearRetainingCapacity();
        order.clearRetainingCapacity();
    }
}

fn expectLevelsAndReorder(
    paragraph_level: Level,
    chars: []const u32,
    cats: []const BidiCat,
    expected_levels: []const ?Level,
    expected_order: []const usize,
) !void {
    const actual_levels = resolve(std.testing.allocator, chars, cats, paragraph_level) catch |e| {
        std.debug.print("\nFAILED BIDI RESOLVE\n", .{});
        return e;
    };
    defer std.testing.allocator.free(actual_levels);
    std.testing.expectEqual(expected_levels.len, actual_levels.len) catch |e| {
        std.debug.print("\nFAILED BIDI LEVELS LEN\n", .{});
        return e;
    };

    const actual_order = reorder(std.testing.allocator, cats, actual_levels, paragraph_level) catch |e| {
        std.debug.print("\nFAILED BIDI REORDER\n", .{});
        return e;
    };
    defer std.testing.allocator.free(actual_order);

    for (0..actual_levels.len) |i| {
        const expected = expected_levels[i];
        const actual = actual_levels[i];
        if (expected) |exp| {
            std.testing.expectEqual(exp, actual) catch |e| {
                std.debug.print("\nFAILED BIDI LEVEL CASE\n", .{});
                return e;
            };
        }
    }

    for (expected_order, 0..) |expected, i| {
        const actual = actual_order[i];
        std.testing.expectEqual(expected, actual) catch |e| {
            std.debug.print("\nFAILED BIDI ORDER CASE\n", .{});
            return e;
        };
    }
}

const DebugPrint = struct {
    levels: []const ?Level = undefined,
    order: []const usize = undefined,
    cats: []const BidiCat = undefined,
    line: usize = 1,

    fn print(self: @This()) void {
        debugPrintItems("Expected levels", self.levels);
        debugPrintItems("Expected order", self.order);
        debugPrintCats("Original cats", self.cats);
        std.debug.print("Line: {}\n", .{self.line});
    }
};

fn debugPrintItems(context: []const u8, items: anytype) void {
    std.debug.print("{s}: .{{", .{context});
    for (items, 0..) |item, i| {
        if (i > 0) {
            std.debug.print(", ", .{});
        }
        if (@typeInfo(@TypeOf(item)) == .Optional) {
            std.debug.print("{}({?})", .{ i, item });
        } else {
            std.debug.print("{}({})", .{ i, item });
        }
    }
    std.debug.print("}}, \n", .{});
}

fn debugPrintCats(context: []const u8, items: anytype) void {
    std.debug.print("{s}: .{{ ", .{context});
    for (items, 0..) |item, i| {
        if (i > 0) {
            std.debug.print(", ", .{});
        }
        const cat = if (@TypeOf(item) == BidiCat) item else item.bidi;
        std.debug.print("{}({s})", .{ i, @tagName(cat) });
    }
    std.debug.print("}}, \n", .{});
}
