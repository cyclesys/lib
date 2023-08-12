const std = @import("std");
const ucd = @import("ucd.zig");
const WordBreakProperty = @import("ucd/WordBreakProperty.zig");

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

    var state = WordState.init(self);
    var i = self.i;
    while (true) : (i += 1) {
        if (i >= self.chars.len) {
            return state.end();
        }

        const prop = ucd.trieValue(WordBreakProperty, self.chars[i]);
        return state.next(prop) orelse continue;
    }
}

const WordState = struct {
    iter: *Self,
    peek_i: usize,
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
            .peek_i = 0,
            .zwj = null,
            .rule = null,
        };
    }

    fn next(self: *WordState, prop: WordBreakProperty.Value) ?usize {
        if (self.rule == null) {
            self.iter.i += 1;
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
                .LF => self.finalizeAdvance(),
                else => self.finalize(),
            },
            .Whitespace => switch (prop) {
                .WSegSpace => self.advance(null),
                else => self.advanceIfIgnoreAndSetIgnore(prop),
            },
            .ZWJ => {
                switch (prop) {
                    .Extended_Pictographic => {
                        self.zwj = null;
                        return self.advance(.Any);
                    },
                    .ZWJ => {
                        if (self.zwj) |zwj| {
                            if (zwj.is_advance) {
                                return self.advance(null);
                            } else {
                                return self.peek(null);
                            }
                        }
                        return self.advance(null);
                    },
                    .Extend, .Format => {
                        if (self.zwj) |zwj| {
                            self.rule = zwj.rule;
                            const is_advance = zwj.is_advance;
                            self.zwj = null;
                            if (is_advance) {
                                return self.advance(null);
                            } else {
                                return self.peek(null);
                            }
                        }
                        return self.advance(.Ignore);
                    },
                    else => {
                        if (self.zwj) |zwj| {
                            self.rule = zwj.rule;
                            self.zwj = null;
                            return self.next(prop);
                        }
                        return self.finalize();
                    },
                }
            },
            .Ignore => switch (prop) {
                .ZWJ => self.advance(null),
                .Extend, .Format => self.advance(null),
                else => self.finalize(),
            },
            .ALetter => switch (prop) {
                .ALetter => self.advance(null),
                .Hebrew_Letter => self.advance(.HebrewLetter),
                .MidLetter, .MidNumLet, .Single_Quote => self.peek(.AHLetterMid),
                .Numeric => self.advance(.Numeric),
                .ExtendNumLet => self.advance(.ExtendNumLet),
                else => self.advanceIfIgnore(prop),
            },
            .HebrewLetter => switch (prop) {
                .ALetter => self.advance(.ALetter),
                .Hebrew_Letter => self.advance(null),
                .MidLetter, .MidNumLet => self.peek(.AHLetterMid),
                .Single_Quote => self.finalizeAdvance(),
                .Double_Quote => self.peek(.HebrewLetterDQ),
                .Numeric => self.advance(.Numeric),
                .ExtendNumLet => self.advance(.ExtendNumLet),
                else => self.advanceIfIgnore(prop),
            },
            .AHLetterMid => switch (prop) {
                .ALetter => self.advance(.ALetter),
                .Hebrew_Letter => self.advance(.HebrewLetter),
                else => self.peekIfIgnore(prop),
            },
            .HebrewLetterDQ => switch (prop) {
                .Hebrew_Letter => self.advance(.HebrewLetter),
                else => self.advanceIfIgnore(prop),
            },
            .Numeric => switch (prop) {
                .Numeric => self.advance(null),
                .ALetter => self.advance(.ALetter),
                .Hebrew_Letter => self.advance(.HebrewLetter),
                .MidNum, .MidNumLet, .Single_Quote => self.peek(.NumericMid),
                .ExtendNumLet => self.advance(.ExtendNumLet),
                else => self.advanceIfIgnore(prop),
            },
            .NumericMid => switch (prop) {
                .Numeric => self.advance(.Numeric),
                else => self.peekIfIgnore(prop),
            },
            .Katakana => switch (prop) {
                .Katakana => self.advance(null),
                .ExtendNumLet => self.advance(.ExtendNumLet),
                else => self.advanceIfIgnore(prop),
            },
            .ExtendNumLet => switch (prop) {
                .ALetter => self.advance(.ALetter),
                .Hebrew_Letter => self.advance(.HebrewLetter),
                .Numeric => self.advance(.Numeric),
                .Katakana => self.advance(.Katakana),
                .ExtendNumLet => self.advance(null),
                else => self.advanceIfIgnore(prop),
            },
            .RegionalIndicator => switch (prop) {
                .Regional_Indicator => blk: {
                    if (((self.iter.ris_count) % 2) == 0) {
                        break :blk self.finalize();
                    }
                    self.iter.ris_count += 1;
                    break :blk self.advance(null);
                },
                else => self.advanceIfIgnore(prop),
            },
            .Any => self.advanceIfIgnore(prop),
        };
    }

    fn end(self: *WordState) usize {
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

    inline fn advanceIfIgnore(self: *WordState, prop: WordBreakProperty.Value) ?usize {
        return switch (prop) {
            .ZWJ => {
                self.zwj = .{
                    .rule = self.rule.?,
                    .is_advance = true,
                };
                return self.advance(.ZWJ);
            },
            .Extend, .Format => self.advance(null),
            else => self.finalize(),
        };
    }

    inline fn advanceIfIgnoreAndSetIgnore(self: *WordState, prop: WordBreakProperty.Value) ?usize {
        return switch (prop) {
            .ZWJ => self.advance(.ZWJ),
            .Extend, .Format => self.advance(.Ignore),
            else => self.finalize(),
        };
    }

    inline fn advance(self: *WordState, comptime rule: ?Rule) ?usize {
        if (rule) |r| {
            self.rule = r;
        }
        self.iter.i += 1 + self.peek_i;
        self.peek_i = 0;
        return null;
    }

    inline fn peekIfIgnore(self: *WordState, prop: WordBreakProperty.Value) ?usize {
        return switch (prop) {
            .ZWJ => {
                self.zwj = .{
                    .rule = self.rule.?,
                    .is_advance = false,
                };
                return self.peek(.ZWJ);
            },
            .Extend, .Format => self.peek(null),
            else => self.finalize(),
        };
    }

    inline fn peek(self: *WordState, comptime rule: ?Rule) ?usize {
        if (rule) |r| {
            self.rule = r;
        }
        self.peek_i += 1;
        return null;
    }

    inline fn finalizeAdvance(self: *WordState) usize {
        self.iter.i += 1;
        return self.finalizePeek();
    }

    inline fn finalizePeek(self: *WordState) usize {
        self.iter.i += self.peek_i;
        return self.finalize();
    }

    inline fn finalize(self: *WordState) usize {
        return self.iter.i - 1;
    }
};

test {
    try ucd.testBreakIterator("WordBreakTest.txt", init);
}
