const std = @import("std");
const ucd = @import("ucd/break.zig");

pub const GraphemeIterator = struct {
    str: []const u8,
    offset: usize,
    ris_count: usize,
    cached_table_item: ?ucd.GraphemeBreakTableItem,

    pub fn init(str: []const u8) GraphemeIterator {
        return GraphemeIterator{
            .str = str,
            .offset = 0,
            .ris_count = 0,
            .cached_table_item = null,
        };
    }

    pub fn next(self: *GraphemeIterator) !?[]const u8 {
        if (self.offset == self.str.len) {
            return null;
        }

        const start = self.offset;
        var iter = std.unicode.Utf8Iterator{
            .bytes = self.str[start..],
            .i = 0,
        };

        var code_point = iter.nextCodepointSlice().?;
        var before = try self.graphemeProperty(code_point, true);
        var prev_offset = self.offset;
        while (true) {
            self.offset += code_point.len;

            var after: ucd.GraphemeBreakProperty = undefined;
            if (iter.nextCodepointSlice()) |next_code_point| {
                code_point = next_code_point;
                after = try self.graphemeProperty(code_point, true);
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
                            const prev = try self.graphemeProperty(prev_code_point, false);
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

    inline fn defaultAfter(after: ucd.GraphemeBreakProperty) bool {
        return switch (after) {
            .Extend, .ZWJ, .SpacingMark => false,
            else => true,
        };
    }

    fn graphemeProperty(self: *GraphemeIterator, code_point: []const u8, cache_item: bool) !ucd.GraphemeBreakProperty {
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

        if (self.cached_table_item) |cached_item| {
            if (cached_item[0] <= unit and unit <= cached_item[1]) {
                return cached_item[2];
            }
        }

        const item = matchTableItem(
            ucd.GraphemeBreakTableItem,
            unit,
            &ucd.grapheme_break_lookup,
            &ucd.grapheme_break_table,
            1443,
            1449,
        );

        if (cache_item) {
            self.cached_table_item = item;
        }

        return item[2];
    }
};

pub const WordIterator = struct {
    str: []const u8,
    offset: usize,
    ris_count: usize,
    cached_table_item: ?ucd.WordBreakTableItem,

    const WordState = struct {
        iter: *WordIterator,
        start: usize,
        peek_offset: usize,
        zwj: ?struct {
            is_advance: bool,
            rule: Rule,
        },
        rule: ?Rule,

        const Rule = enum {
            CRLF,
            Whitespace,
            ZWJ,
            Ignore,
            ALetter,
            AHLetterMid,
            HebrewLetter,
            HebrewLetterDQ,
            Numeric,
            NumericMid,
            Katakana,
            ExtendNumLet,
            RegionalIndicator,
            Any,
        };

        fn init(iter: *WordIterator) WordState {
            return WordState{
                .iter = iter,
                .start = iter.offset,
                .peek_offset = 0,
                .zwj = null,
                .rule = null,
            };
        }

        fn next(self: *WordState, code_point: []const u8, prop: ucd.WordBreakProperty) ?[]const u8 {
            if (self.rule == null) {
                self.iter.offset += code_point.len;
                self.rule = switch (prop) {
                    .CR => .CRLF,
                    .LF, .Newline => return self.finalize(),
                    .WSegSpace => .Whitespace,
                    .ZWJ => .ZWJ,
                    .Extend, .Format => .Ignore,
                    .ALetter => .ALetter,
                    .Hebrew_Letter => .HebrewLetter,
                    .Numeric => .Numeric,
                    .Katakana => .Katakana,
                    .ExtendNumLet => .ExtendNumLet,
                    .Regional_Indicator => .RegionalIndicator,
                    else => .Any,
                };
                if (self.rule.? == .RegionalIndicator) {
                    self.iter.ris_count += 1;
                } else {
                    self.iter.ris_count = 0;
                }
                return null;
            }

            return switch (self.rule.?) {
                .CRLF => switch (prop) {
                    .LF => self.finalizeAdvance(code_point),
                    else => self.finalize(),
                },
                .Whitespace => switch (prop) {
                    .WSegSpace => self.advance(code_point, null),
                    else => self.advanceIfIgnoreAndSetIgnore(code_point, prop),
                },
                .ZWJ => {
                    switch (prop) {
                        .Extended_Pictographic => {
                            self.zwj = null;
                            return self.advance(code_point, .Any);
                        },
                        .ZWJ => {
                            if (self.zwj) |zwj| {
                                if (zwj.is_advance) {
                                    return self.advance(code_point, null);
                                } else {
                                    return self.peek(code_point, null);
                                }
                            }
                            return self.advance(code_point, null);
                        },
                        .Extend, .Format => {
                            if (self.zwj) |zwj| {
                                self.rule = zwj.rule;
                                const is_advance = zwj.is_advance;
                                self.zwj = null;
                                if (is_advance) {
                                    return self.advance(code_point, null);
                                } else {
                                    return self.peek(code_point, null);
                                }
                            }
                            return self.advance(code_point, .Ignore);
                        },
                        else => {
                            if (self.zwj) |zwj| {
                                self.rule = zwj.rule;
                                self.zwj = null;
                                return self.next(code_point, prop);
                            }
                            return self.finalize();
                        },
                    }
                },
                .Ignore => switch (prop) {
                    .ZWJ => self.advance(code_point, null),
                    .Extend, .Format => self.advance(code_point, null),
                    else => self.finalize(),
                },
                .ALetter => switch (prop) {
                    .ALetter => self.advance(code_point, null),
                    .Hebrew_Letter => self.advance(code_point, .HebrewLetter),
                    .MidLetter, .MidNumLet, .Single_Quote => self.peek(code_point, .AHLetterMid),
                    .Numeric => self.advance(code_point, .Numeric),
                    .ExtendNumLet => self.advance(code_point, .ExtendNumLet),
                    else => self.advanceIfIgnore(code_point, prop),
                },
                .HebrewLetter => switch (prop) {
                    .ALetter => self.advance(code_point, .ALetter),
                    .Hebrew_Letter => self.advance(code_point, null),
                    .MidLetter, .MidNumLet => self.peek(code_point, .AHLetterMid),
                    .Single_Quote => self.finalizeAdvance(code_point),
                    .Double_Quote => self.peek(code_point, .HebrewLetterDQ),
                    .Numeric => self.advance(code_point, .Numeric),
                    .ExtendNumLet => self.advance(code_point, .ExtendNumLet),
                    else => self.advanceIfIgnore(code_point, prop),
                },
                .AHLetterMid => switch (prop) {
                    .ALetter => self.advance(code_point, .ALetter),
                    .Hebrew_Letter => self.advance(code_point, .HebrewLetter),
                    else => self.peekIfIgnore(code_point, prop),
                },
                .HebrewLetterDQ => switch (prop) {
                    .Hebrew_Letter => self.advance(code_point, .HebrewLetter),
                    else => self.advanceIfIgnore(code_point, prop),
                },
                .Numeric => switch (prop) {
                    .Numeric => self.advance(code_point, null),
                    .ALetter => self.advance(code_point, .ALetter),
                    .Hebrew_Letter => self.advance(code_point, .HebrewLetter),
                    .MidNum, .MidNumLet, .Single_Quote => self.peek(code_point, .NumericMid),
                    .ExtendNumLet => self.advance(code_point, .ExtendNumLet),
                    else => self.advanceIfIgnore(code_point, prop),
                },
                .NumericMid => switch (prop) {
                    .Numeric => self.advance(code_point, .Numeric),
                    else => self.peekIfIgnore(code_point, prop),
                },
                .Katakana => switch (prop) {
                    .Katakana => self.advance(code_point, null),
                    .ExtendNumLet => self.advance(code_point, .ExtendNumLet),
                    else => self.advanceIfIgnore(code_point, prop),
                },
                .ExtendNumLet => switch (prop) {
                    .ALetter => self.advance(code_point, .ALetter),
                    .Hebrew_Letter => self.advance(code_point, .HebrewLetter),
                    .Numeric => self.advance(code_point, .Numeric),
                    .Katakana => self.advance(code_point, .Katakana),
                    .ExtendNumLet => self.advance(code_point, null),
                    else => self.advanceIfIgnore(code_point, prop),
                },
                .RegionalIndicator => switch (prop) {
                    .Regional_Indicator => blk: {
                        if (((self.iter.ris_count) % 2) == 0) {
                            break :blk self.finalize();
                        }
                        self.iter.ris_count += 1;
                        break :blk self.advance(code_point, null);
                    },
                    else => self.advanceIfIgnore(code_point, prop),
                },
                .Any => self.advanceIfIgnore(code_point, prop),
            };
        }

        fn end(self: *WordState) []const u8 {
            return switch (self.rule.?) {
                .AHLetterMid, .NumericMid, .HebrewLetterDQ => self.finalize(),
                .ZWJ => {
                    if (self.zwj) |zwj| {
                        switch (zwj.rule) {
                            .AHLetterMid, .NumericMid, .HebrewLetterDQ => {
                                return self.finalize();
                            },
                            else => {},
                        }
                    }
                    return self.finalizePeek();
                },
                else => self.finalizePeek(),
            };
        }

        inline fn advanceIfIgnore(self: *WordState, code_point: []const u8, prop: ucd.WordBreakProperty) ?[]const u8 {
            return switch (prop) {
                .ZWJ => {
                    self.zwj = .{
                        .rule = self.rule.?,
                        .is_advance = true,
                    };
                    return self.advance(code_point, .ZWJ);
                },
                .Extend, .Format => self.advance(code_point, null),
                else => self.finalize(),
            };
        }

        inline fn advanceIfIgnoreAndSetIgnore(
            self: *WordState,
            code_point: []const u8,
            prop: ucd.WordBreakProperty,
        ) ?[]const u8 {
            return switch (prop) {
                .ZWJ => self.advance(code_point, .ZWJ),
                .Extend, .Format => self.advance(code_point, .Ignore),
                else => self.finalize(),
            };
        }

        inline fn advance(self: *WordState, code_point: []const u8, comptime rule: ?Rule) ?[]const u8 {
            if (rule) |r| {
                self.rule = r;
            }
            self.iter.offset += code_point.len + self.peek_offset;
            self.peek_offset = 0;
            return null;
        }

        inline fn peekIfIgnore(self: *WordState, code_point: []const u8, prop: ucd.WordBreakProperty) ?[]const u8 {
            return switch (prop) {
                .ZWJ => {
                    self.zwj = .{
                        .rule = self.rule.?,
                        .is_advance = false,
                    };
                    return self.peek(code_point, .ZWJ);
                },
                .Extend, .Format => self.peek(code_point, null),
                else => self.finalize(),
            };
        }

        inline fn peek(self: *WordState, code_point: []const u8, comptime rule: ?Rule) ?[]const u8 {
            if (rule) |r| {
                self.rule = r;
            }
            self.peek_offset += code_point.len;
            return null;
        }

        inline fn finalizeAdvance(self: *WordState, code_point: []const u8) []const u8 {
            self.iter.offset += code_point.len;
            return self.finalizePeek();
        }

        inline fn finalizePeek(self: *WordState) []const u8 {
            self.iter.offset += self.peek_offset;
            return self.finalize();
        }

        inline fn finalize(self: *WordState) []const u8 {
            return self.iter.str[self.start..self.iter.offset];
        }
    };

    pub fn init(str: []const u8) WordIterator {
        return WordIterator{
            .str = str,
            .offset = 0,
            .ris_count = 0,
            .cached_table_item = null,
        };
    }

    pub fn next(self: *WordIterator) !?[]const u8 {
        if (self.offset == self.str.len) {
            return null;
        }

        var state = WordState.init(self);
        var iter = std.unicode.Utf8Iterator{ .bytes = self.str[state.start..], .i = 0 };
        while (true) {
            const code_point = if (iter.nextCodepointSlice()) |slice| slice else {
                if (self.offset + state.peek_offset != self.str.len) {
                    return error.InvalidUtf8;
                }
                return state.end();
            };
            const prop = try self.wordProperty(code_point);
            return state.next(code_point, prop) orelse continue;
        }
    }

    inline fn wordProperty(self: *WordIterator, code_point: []const u8) !ucd.WordBreakProperty {
        const unit: u32 = @intCast(try std.unicode.utf8Decode(code_point));

        if (self.cached_table_item) |cached_item| {
            if (cached_item[0] <= unit and unit <= cached_item[1]) {
                return cached_item[2];
            }
        }

        const item = matchTableItem(
            ucd.WordBreakTableItem,
            unit,
            &ucd.word_break_lookup,
            &ucd.word_break_table,
            1050,
            1053,
        );
        self.cached_table_item = item;
        return item[2];
    }
};

pub const SentenceIterator = struct {
    str: []const u8,
    offset: usize,
    cached_table_item: ?ucd.SentenceBreakTableItem,

    const SentenceState = struct {
        iter: *SentenceIterator,
        start: usize,
        peek_offset: usize,
        rule: ?Rule,

        const Rule = enum {
            CRLF,
            Ignore,
            ATerm,
            ATermClose,
            ATermSp,
            STerm,
            STermClose,
            STermSp,
            UpperLower,
            UpperLowerATerm,
            Any,
        };

        fn init(iter: *SentenceIterator) SentenceState {
            return SentenceState{
                .iter = iter,
                .start = iter.offset,
                .peek_offset = 0,
                .rule = null,
            };
        }

        fn next(self: *SentenceState, code_point: []const u8, prop: ucd.SentenceBreakProperty) ?[]const u8 {
            if (self.rule == null) {
                return self.nextAny(code_point, prop);
            }

            return switch (self.rule.?) {
                .CRLF => switch (prop) {
                    .LF => self.finalizeAdvance(code_point),
                    else => self.finalize(),
                },
                .Ignore => switch (prop) {
                    .Extend, .Format => self.advance(code_point, null),
                    else => self.finalize(),
                },
                .ATerm => self.nextATerm(code_point, prop),
                .ATermClose, .ATermSp => switch (prop) {
                    .Lower => self.peek(code_point, .Any),
                    else => self.nextATerm(code_point, prop),
                },
                .STerm, .STermClose, .STermSp => switch (prop) {
                    .Extend, .Format => self.advance(code_point, null),
                    .ATerm => self.advance(code_point, .ATerm),
                    .STerm => self.advance(code_point, null),
                    .Close => switch (self.rule.?) {
                        .STermSp => self.finalize(),
                        else => self.advance(code_point, .STermClose),
                    },
                    .Sp => self.advance(code_point, .STermSp),
                    .SContinue => self.advance(code_point, .Any),
                    .CR => self.advance(code_point, .CRLF),
                    .Sep, .LF => self.finalizeAdvance(code_point),
                    else => self.finalize(),
                },
                .UpperLower => switch (prop) {
                    .ATerm => self.peek(code_point, .UpperLowerATerm),
                    else => self.nextAny(code_point, prop),
                },
                .UpperLowerATerm => switch (prop) {
                    .Upper => self.advance(code_point, .UpperLower),
                    .Extend, .Format => self.advance(code_point, null),
                    else => self.nextATerm(code_point, prop),
                },
                .Any => self.nextAny(code_point, prop),
            };
        }

        fn end(self: *SentenceState) ?[]const u8 {
            return switch (self.rule.?) {
                .UpperLowerATerm => self.finalizePeek(),
                else => self.finalize(),
            };
        }

        inline fn nextAny(self: *SentenceState, code_point: []const u8, prop: ucd.SentenceBreakProperty) ?[]const u8 {
            return switch (prop) {
                .CR => self.advance(code_point, .CRLF),
                .Sep, .LF => self.finalizeAdvance(code_point),
                .Extend, .Format => self.advance(code_point, .Any),
                .ATerm => self.advance(code_point, .ATerm),
                .STerm => self.advance(code_point, .STerm),
                .Upper, .Lower => self.advance(code_point, .UpperLower),
                else => self.advance(code_point, .Any),
            };
        }

        inline fn nextATerm(self: *SentenceState, code_point: []const u8, prop: ucd.SentenceBreakProperty) ?[]const u8 {
            return switch (prop) {
                .Extend, .Format => self.advance(code_point, null),
                .Numeric => self.advance(code_point, .Any),
                .ATerm => self.advance(code_point, null),
                .STerm => self.advance(code_point, .STerm),
                .Close => switch (self.rule.?) {
                    .ATermSp => self.finalize(),
                    else => self.advance(code_point, .ATermClose),
                },
                .Sp => self.advance(code_point, .ATermSp),
                .SContinue => self.advance(code_point, .Any),
                .Lower => self.advance(code_point, .Any),
                .CR => self.advance(code_point, .CRLF),
                .Sep, .LF => self.finalizeAdvance(code_point),
                else => self.finalize(),
            };
        }

        inline fn advance(self: *SentenceState, code_point: []const u8, comptime rule: ?Rule) ?[]const u8 {
            if (rule) |r| {
                self.rule = r;
            }
            self.iter.offset += code_point.len + self.peek_offset;
            self.peek_offset = 0;
            return null;
        }

        inline fn peek(self: *SentenceState, code_point: []const u8, comptime rule: ?Rule) ?[]const u8 {
            if (rule) |r| {
                self.rule = r;
            }
            self.peek_offset += code_point.len;
            return null;
        }

        inline fn finalizeAdvance(self: *SentenceState, code_point: []const u8) []const u8 {
            self.iter.offset += code_point.len;
            return self.finalizePeek();
        }

        inline fn finalizePeek(self: *SentenceState) []const u8 {
            self.iter.offset += self.peek_offset;
            return self.finalize();
        }

        inline fn finalize(self: *SentenceState) []const u8 {
            return self.iter.str[self.start..self.iter.offset];
        }
    };

    pub fn init(str: []const u8) SentenceIterator {
        return SentenceIterator{
            .str = str,
            .offset = 0,
            .cached_table_item = null,
        };
    }

    pub fn next(self: *SentenceIterator) !?[]const u8 {
        if (self.offset == self.str.len) {
            return null;
        }

        var state = SentenceState.init(self);
        var iter = std.unicode.Utf8Iterator{ .bytes = self.str[state.start..], .i = 0 };
        while (true) {
            const code_point = if (iter.nextCodepointSlice()) |slice| slice else {
                if (self.offset + state.peek_offset != self.str.len) {
                    return error.InvalidUtf8;
                }
                return state.end();
            };
            const prop = try self.sentenceProperty(code_point);
            return state.next(code_point, prop) orelse continue;
        }
    }

    inline fn sentenceProperty(self: *SentenceIterator, code_point: []const u8) !ucd.SentenceBreakProperty {
        const unit: u32 = @intCast(try std.unicode.utf8Decode(code_point));

        if (self.cached_table_item) |cached_item| {
            if (cached_item[0] <= unit and unit <= cached_item[1]) {
                return cached_item[2];
            }
        }

        const item = matchTableItem(
            ucd.SentenceBreakTableItem,
            unit,
            &ucd.sentence_break_lookup,
            &ucd.sentence_break_table,
            2410,
            2421,
        );
        self.cached_table_item = item;
        return item[2];
    }
};

fn matchTableItem(
    comptime Item: type,
    unit: u32,
    lookup: []const u32,
    table: []const Item,
    default_start: usize,
    default_end: usize,
) Item {
    const idx: usize = (unit / ucd.break_lookup_interval);

    const lookup_len = lookup.len;
    const lookup_slice = if (idx + 2 <= lookup_len)
        table[lookup[idx] .. lookup[idx + 1] + 1]
    else
        table[default_start..default_end];

    switch (binarySearchTable(unit, lookup_slice)) {
        .Found => |i| return lookup_slice[i],
        .NotFound => |i| {
            const lower = idx * ucd.break_lookup_interval;
            const upper = lower + ucd.break_lookup_interval - 1;

            const begin = if (i > 0) lookup_slice[i - 1][1] + 1 else lower;
            const end = if (i < lookup_slice.len) lookup_slice[i][0] - 1 else upper;

            return .{ @intCast(begin), @intCast(end), .Any };
        },
    }
}

fn binarySearchTable(unit: u32, table: anytype) union(enum) {
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

test "reverse iterator" {
    var iter = ReverseUtf8Iterator.init("東京市");
    try std.testing.expect(std.mem.eql(u8, "市", iter.next().?));
    try std.testing.expect(std.mem.eql(u8, "京", iter.next().?));
    try std.testing.expect(std.mem.eql(u8, "東", iter.next().?));
}

test "grapheme break iterator" {
    try testBreakIterator(&ucd_test.grapheme_test_cases, GraphemeIterator.init);
}

test "word break iterator" {
    try testBreakIterator(&ucd_test.word_test_cases, WordIterator.init);
}

test "sentence break iterator" {
    try testBreakIterator(&ucd_test.sentence_test_cases, SentenceIterator.init);
}

fn testBreakIterator(cases: anytype, initFn: anytype) !void {
    for (cases, 0..) |case, i| {
        var iter = initFn(case[0]);
        const expected = case[1];
        var idx: usize = 0;
        while (try iter.next()) |str| : (idx += 1) {
            var actual: u32 = undefined;
            var code_point_iter = std.unicode.Utf8Iterator{
                .bytes = str,
                .i = 0,
            };
            while (code_point_iter.nextCodepoint()) |cp| {
                actual = @intCast(cp);
            }
            std.testing.expectEqual(expected[idx], actual) catch |e| {
                std.log.warn("FAILED TEST CASE: {} -- {}\n", .{ i, idx });
                std.log.warn("EXPECTED: {x}, ACTUAL: {x}\n", .{ expected[idx], actual });
                return e;
            };
        }
        try std.testing.expectEqual(expected.len, idx);
    }
}
