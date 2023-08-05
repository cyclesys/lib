const std = @import("std");
const ucd = @import("ucd.zig");
const CharInfo = @import("CharInfo.zig");
const BidiBrackets = @import("ucd/BidiBrackets.zig");
const BidiCategory = @import("ucd/BidiCategory.zig");

pub const Level = u8;

pub fn resolve(allocator: std.mem.Allocator, chars: []const u32, infos: []const CharInfo) ![]const Level {
    std.debug.assert(chars.len == infos.len);

    var levels = try allocator.alloc(Level, chars.len);

    var cats = try allocator.alloc(BidiCategory.Value, chars.len);
    defer allocator.free(cats);

    var iter = ParagraphIterator{ .chars = chars, .infos = infos };
    while (iter.next()) |paragraph| {
        const paragraph_chars = chars[paragraph.start..paragraph.end];
        const paragraph_infos = infos[paragraph.start..paragraph.end];
        const paragraph_levels = levels[paragraph.start..paragraph.end];
        const paragraph_cats = cats[paragraph.start..paragraph.end];

        resolveExplicit(paragraph_infos, paragraph_levels, paragraph_cats, paragraph.level);

        const paragraph_sequences = try resolveSequences(allocator, paragraph_levels, paragraph_cats, paragraph.level);
        defer allocator.free(paragraph_sequences);

        resolveWeakTypes(paragraph_sequences);
        try resolveNeutralTypes(allocator, paragraph_chars, paragraph_cats, paragraph_sequences);
        resolveImplicitLevels(paragraph_levels, paragraph_cats, paragraph_sequences);
    }

    return levels;
}

const ParagraphIterator = struct {
    chars: []const u32,
    infos: []const CharInfo,
    i: usize = 0,

    fn next(self: *ParagraphIterator) ?Paragraph {
        if (self.i >= self.chars.len) {
            return null;
        }

        const start = self.i;
        var isolate_count: usize = 0;
        var level: ?u8 = null;
        for (self.infos[start..]) |info| {
            self.i += 1;
            switch (info.bidi) {
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
                else => continue,
            }
        }

        return Paragraph{
            .start = start,
            .end = self.i,
            .level = level orelse 0,
        };
    }
};

fn resolveImplicitLevels(levels: []Level, cats: []const BidiCategory.Value, sequences: []Sequence) void {
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

fn resolveNeutralTypes(
    allocator: std.mem.Allocator,
    chars: []const u32,
    cats: []BidiCategory.Value,
    sequences: []const Sequence,
) !void {
    for (sequences) |seq| {
        const dir: BidiCategory.Value = if (seq.level % 2 == 0) .L else .R;

        const pairs = try resolveBracketPairs(allocator, seq);
        defer allocator.free(pairs);

        outer: for (pairs) |pair| {
            var strong_type: ?BidiCategory.Value = null;
            for (pair.opening.ri..(pair.closing.ri + 1)) |ri| {
                const start = if (ri == pair.opening.ri) pair.opening.ii else seq.runs[ri].start;
                const end = if (ri == pair.closing.ri) pair.closing.ii else seq.runs[ri].end;
                for (start..end) |ii| {
                    var cat = switch (cats[ii]) {
                        .EN, .AN => .R,
                        else => |cat| cat,
                    };
                    if (cat == dir) {
                        seq.get(pair.opening).cat = dir;
                        seq.get(pair.closing).cat = dir;
                        checkNSMAfterPairedBracket(seq, pair.opening, chars, cats, dir);
                        checkNSMAfterPairedBracket(seq, pair.closing, chars, cats, dir);
                        continue :outer;
                    }

                    if (cat == .L or cat == .R) {
                        strong_type = cat;
                    }
                }
            }

            if (strong_type == null) {
                continue :outer;
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

            const new_cat = if (context == strong_type.?) context else dir;
            cats[pair.opening.ii] = new_cat;
            cats[pair.closing.ii] = new_cat;
            checkNSMAfterPairedBracket(seq, pair.opening, chars, cats, new_cat);
            checkNSMAfterPairedBracket(seq, pair.closing, chars, cats, new_cat);
        }

        var prev_char: ?usize = null;
        var ni_seq_ctx: ?BidiCategory.Value = null;
        var ni_seq_start: ?Sequence.Pos = null;
        for (seq.runs, 0..) |run, ri| {
            for (run.start..run.end) |ii| {
                const prev = prev_char;
                prev_char = ii;
                switch (cats[ii]) {
                    .B, .S, .WS, .ON, .FSI, .LRI, .RLI, .PDI => {
                        if (ni_seq_start) |*nss| {
                            nss.* += 1;
                            continue;
                        }

                        if (prev) |p| {
                            switch (cats[p]) {
                                .L, .R, .EN, .AN => {
                                    ni_seq_ctx = p.cat;
                                },
                                .EN, .AN => {
                                    ni_seq_ctx = .R;
                                },
                                else => {
                                    cats[ii] = dir;
                                    continue;
                                },
                            }
                            ni_seq_start = Sequence.Pos{
                                .ri = ri,
                                .ii = ii,
                            };
                        }
                    },
                    .L, .R, .AN, .EN => {
                        if (ni_seq_start) |start| {
                            const context = if (cats[ii] == .AN or cats[ii] == .EN) .R else cats[ii];
                            if (ni_seq_ctx.? == context) {
                                setAllInSequence(seq, start, Sequence.Pos{ .ri = ri, .ii = ii }, cats, context);
                            } else {
                                setAllInSequence(seq, start, Sequence.Pos{ .ri = ri, .ii = ii }, cats, dir);
                            }

                            ni_seq_ctx = null;
                            ni_seq_start = null;
                        }
                    },
                    else => {
                        if (ni_seq_start) |start| {
                            setAllInSequence(seq, start, Sequence.Pos{ .ri = ri, .ii = ii }, cats, dir);
                            ni_seq_ctx = null;
                            ni_seq_start = null;
                        }
                    },
                }
            }
        }
    }
}

fn checkNSMAfterPairedBracket(
    seq: Sequence,
    pos: Sequence.Pos,
    chars: []const u32,
    cats: []BidiCategory.Value,
    cat: BidiCategory.Value,
) void {
    var ri = pos.ri;
    var ii = pos.ii + 1;
    outer: while (ri < seq.runs.len) : (ri += 1) {
        while (ii < seq.runs[ri].end) : (ii += 1) {
            switch (try ucd.trieValue(BidiCategory, chars[ii])) {
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
    cats: []BidiCategory.Value,
    cat: BidiCategory.Value,
) void {
    for (start.ri..(end.ri + 1)) |ri| {
        const start_idx = if (ri == start.ri) start.ii else seq.runs[ri].start;
        const end_idx = if (ri == end.ri) end.ii + 1 else seq.runs[ri].end;
        for (start_idx..end_idx) |ii| {
            cats[ii] = cat;
        }
    }
}

fn resolveBracketPairs(
    allocator: std.mem.Allocator,
    seq: Sequence,
    chars: []const u32,
    cats: []const BidiCategory.Value,
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
        }

        fn pop(self: *@This(), new_len: usize) void {
            self.stack_len = new_len;
        }
    } = .{ .pairs = std.ArrayList(BracketPair).init(allocator) };

    outer: for (seq.runs, 0..) |run, ri| {
        for (run.start..run.end) |ii| {
            // skip resolved characters
            if (cats[ii] == .L or cats[ii] == .R) continue;

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
                            if (entry.bracket.pair == chars[ii]) {
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
        undefined,
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

fn resolveWeakTypes(cats: []BidiCategory.Value, sequences: []const Sequence) void {
    const Prev = struct {
        cat: BidiCategory.Value,
        ii: usize,
    };
    for (sequences) |seq| {
        var strong_type = seq.sos;
        var prev: ?Prev = null;
        var prev_prev: ?Prev = null;
        var et_seq_start: ?Sequence.Pos = null;
        for (seq.runs, 0..) |run, ri| {
            for (run.start..run.end) |ii| {
                const cat = cats[ii];
                const old_prev = prev;
                const old_prev_prev = prev_prev;
                prev_prev = prev;
                prev = Prev{
                    .cat = cat,
                    .ii = ii,
                };
                var reset_et_seq_start = true;
                switch (cat) {
                    .NSM => {
                        cats[ii] = if (old_prev) |p|
                            switch (p.cat) {
                                .RLI, .LRI, .FSI, .PDI => .ON,
                                else => p.cat,
                            }
                        else
                            seq.sos;
                    },
                    .R, .L => {
                        strong_type = cat;
                    },
                    .AL => {
                        strong_type = .AL;
                        cats[ii] = .R;
                    },
                    .EN => {
                        if (strong_type == .AL) {
                            cats[ii] = .AN;
                            prev = .AN;
                        } else {
                            if (old_prev) |p| {
                                if (p.cat == .CS or p.cat == .ES) {
                                    if (old_prev_prev) |pp| {
                                        if (pp.cat == .EN) {
                                            cats[p.ii] = .EN;
                                        }
                                    }
                                }
                            } else if (et_seq_start) |ess| {
                                for (ess.ri..(ri + 1)) |i| {
                                    const start = if (i == ess.ri) ess.ii else seq.runs[i].start;
                                    const end = if (i == ri) ii else seq.runs[i].end;
                                    for (start..end) |ci| {
                                        cats[ci] = .EN;
                                    }
                                }
                            }

                            if (strong_type == .L) {
                                cats[ii] = .L;
                            }
                        }
                    },
                    .AN => {
                        if (old_prev) |p| {
                            if (p.cat == .CS) {
                                if (old_prev_prev) |pp| {
                                    if (pp.cat == .AN) {
                                        cats[p.ii] = .AN;
                                    }
                                }
                            }
                        }
                    },
                    .ET => {
                        if (old_prev) |p| {
                            if (p.cat == .EN) {
                                cats[p.ii] = .EN;
                                prev.?.cat = .EN;
                            }
                        } else {
                            if (et_seq_start == null) {
                                et_seq_start = .{ .ri = ri, .ii = ii };
                            }
                            cats[ii] = .ON;
                            reset_et_seq_start = false;
                        }
                    },
                    .ES, .CS => {
                        cats[ii] = .ON;
                    },
                    else => {
                        // do nothing
                    },
                }
                if (reset_et_seq_start) {
                    et_seq_start = null;
                }
            }
        }
    }
}

fn resolveSequences(
    allocator: std.mem.Allocator,
    levels: []const Level,
    cats: []const BidiCategory.Value,
    paragraph_level: Level,
) ![]const Sequence {
    const SequenceLevelRuns = std.ArrayList(LevelRun);

    var seqs_runs = std.ArrayList(SequenceLevelRuns).init(allocator);
    defer seqs_runs.deinit();

    var stack = std.ArrayList(SequenceLevelRuns).init(allocator);
    defer stack.deinit();

    var iter = LevelRunIterator{ .levels = levels };
    while (iter.next()) |run| {
        const start_cat = cats[run.start];
        const end_cat = cats[run.end - 1];

        var seq = if (start_cat == .PDI and stack.len > 0)
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
        const start_run = seq_runs.items[0];
        const end_run = seq_runs.getLast();

        var boundary_level = if (start_run.start > 0) levels[start_run.start - 1] else paragraph_level;
        boundary_level = @max(levels[start_run.start], boundary_level);
        const sos = if (boundary_level % 2 == 0) .L else .R;

        boundary_level = if (end_run.end < levels.len and switch (cats[end_run.end]) {
            .RLI, .LRI, .FSI => false,
            else => true,
        })
            levels[end_run.end]
        else
            paragraph_level;
        boundary_level = @max(levels[end_run.end - 1], boundary_level);
        const eos = if (boundary_level % 2 == 0) .L else .R;

        var runs = try std.ArrayList(LevelRun).initCapacity(allocator, seq_runs.items.len);
        for (seq_runs.items) |run| {
            try runs.append(run);
        }

        try seqs.append(Sequence{
            .level = start_run.level,
            .runs = try runs.toOwnedSlice(),
            .sos = sos,
            .eos = eos,
        });
    }

    return try seqs.toOwnedSlice();
}

const Sequence = struct {
    level: Level,
    runs: []const LevelRun,
    sos: BidiCategory.Value,
    eos: BidiCategory.Value,

    const Pos = struct {
        ri: usize,
        ii: usize,
    };
};

const LevelRunIterator = struct {
    levels: []const Level,
    i: usize = 0,

    fn next(self: *LevelRunIterator) ?LevelRun {
        if (self.i >= self.levels.len) {
            return null;
        }

        const start = self.i;
        const level: u8 = self.levels[start];
        self.i += 1;
        for (self.levels[self.i..]) |lvl| {
            self.i += 1;
            if (lvl != level) {
                break;
            }
        }

        return LevelRun{
            .level = level,
            .start = start,
            .end = self.i,
        };
    }
};

const LevelRun = struct {
    level: Level,
    start: usize,
    end: usize,
};

fn resolveExplicit(
    infos: []const CharInfo,
    levels: []Level,
    cats: []BidiCategory.Value,
    paragraph_level: Level,
) void {
    const max_depth = 125;
    var state: struct {
        levels: []Level,
        cats: []BidiCategory.Value,
        stack: [stack_size]DirectionalStatus = undefined,
        stack_len: usize = 0,
        overflow_isolate: usize = 0,
        overflow_embedding: usize = 0,
        valid_isolate: usize = 0,

        const stack_size = max_depth + 2;

        const DirectionalStatus = struct {
            level: Level,
            override: ?BidiCategory.Value,
            isolate: bool,
        };

        fn pushEmbedding(self: *@This(), level: Level, override: ?BidiCategory.Value) void {
            if (level <= max_depth and self.overflow_isolate == 0 and self.overflow_embedding == 0) {
                self.push(.{
                    .level = level,
                    .override = override,
                    .isolate = false,
                });
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
                    .override = .neutral,
                    .isolate = true,
                });
            } else {
                self.overflow_isolate += 1;
            }
        }

        fn set(self: *@This(), i: usize, cat: BidiCategory.Value) void {
            const last = self.lastEntry();
            self.levels[i] = last.level;
            self.cats[i] = last.override orelse cat;
        }

        fn push(self: *@This(), entry: DirectionalStatus) void {
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

    for (infos, 0..) |info, i| {
        switch (info.bidi) {
            .RLE => {
                state.pushEmbedding(state.nextOddLevel(), null);
                cats[i] = .RLE;
            },
            .LRE => {
                state.pushEmbedding(state.nextEvenLevel(), null);
                cats[i] = .LRE;
            },
            .RLO => {
                state.pushEmbedding(state.nextOddLevel(), .R);
                cats[i] = .RLO;
            },
            .LRO => {
                state.pushEmbedding(state.nextEvenLevel(), .L);
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
                cats[i] = .PDF;
            },
            .RLI => state.pushRLI(i),
            .LRI => state.pushLRI(i),
            .FSI => {
                var isolate_count: usize = 0;
                const level = for (infos[i..]) |next_info| {
                    switch (next_info.bidi) {
                        .RLI, .LRI, .FSI => {
                            isolate_count += 1;
                        },
                        .PDI => {
                            if (isolate_count > 0) {
                                isolate_count -= 1;
                            } else {
                                break .LRI;
                            }
                        },
                        .L => if (isolate_count == 0) {
                            break .LRI;
                        },
                        .R, .AL => if (isolate_count == 0) {
                            break .RLI;
                        },
                        else => continue,
                    }
                } else .LRI;

                switch (level) {
                    .RLI => state.pushRLI(i),
                    .LRI => state.pushLRI(i),
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
            .B, .BN => |cat| {
                levels[i] = paragraph_level;
                cats[i] = cat;
            },
            else => |cat| state.set(i, cat),
        }
    }
}

const Paragraph = struct {
    start: usize,
    end: usize,
    level: Level,
};
