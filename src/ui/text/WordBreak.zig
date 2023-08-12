const std = @import("std");
const ucd = @import("ucd.zig");
const WordBreakProperty = @import("ucd/WordBreakProperty.zig");

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

    var state = WordState.init(self);
    var iter = std.unicode.Utf8Iterator{ .bytes = self.str[state.start..], .i = 0 };
    while (true) {
        const code_point = if (iter.nextCodepointSlice()) |slice| slice else {
            if (self.offset + state.peek_offset != self.str.len) {
                return error.InvalidUtf8;
            }
            return state.end();
        };
        const prop = try ucd.trieValue(WordBreakProperty, code_point);
        return state.next(code_point, prop) orelse continue;
    }
}

const WordState = struct {
    iter: *Self,
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

    fn init(iter: *Self) WordState {
        return WordState{
            .iter = iter,
            .start = iter.offset,
            .peek_offset = 0,
            .zwj = null,
            .rule = null,
        };
    }

    fn next(self: *WordState, code_point: []const u8, prop: WordBreakProperty.Value) ?[]const u8 {
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

    inline fn advanceIfIgnore(self: *WordState, code_point: []const u8, prop: WordBreakProperty.Value) ?[]const u8 {
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
        prop: WordBreakProperty.Value,
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

    inline fn peekIfIgnore(self: *WordState, code_point: []const u8, prop: WordBreakProperty.Value) ?[]const u8 {
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

test {
    try ucd.testBreakIterator("WordBreakTest.txt", init);
}
