const std = @import("std");
const ucd = @import("ucd.zig");
const ReverseUtf8Iterator = @import("ReverseUtf8Iterator.zig");
const EastAsianWidth = @import("ucd/EastAsianWidth.zig");
const GeneralCategory = @import("ucd/GeneralCategory.zig");
const LineBreakProperty = @import("ucd/LineBreakProperty.zig");

chars: []const u32,
i: usize,
ris_count: usize,
context: Context,
cm_base: ?struct {
    char: u32,
    prop: LineBreakProperty.Value,
},

const Context = enum {
    zw_sp,
    op_sp,
    qu_sp,
    clcp_sp,
    b2_sp,
    hl_hyba,
    none,
};
const Self = @This();

pub const Break = struct {
    mandatory: bool,
    i: usize,
};

pub fn init(chars: []const u32) Self {
    return Self{
        .chars = chars,
        .i = 0,
        .ris_count = 0,
        .context = .none,
        .cm_base = null,
    };
}

pub fn next(self: *Self) ?Break {
    if (self.i >= self.chars.len) {
        return null;
    }

    var before_char = self.chars[self.i];
    var before = prop(before_char);
    var prev_i = self.i;
    self.context = .none;
    while (true) {
        self.i += 1;

        if (self.i >= self.chars.len) {
            return Break{
                .mandatory = true,
                .i = prev_i,
            };
        }

        const after_char = self.chars[self.i];
        const after = prop(after_char);

        if (before == .RI) {
            self.ris_count += 1;
        } else if (before != .CM and before != .ZWJ) {
            self.ris_count = 0;
        }

        if (self.checkPair(before, before_char, after, after_char)) |mandatory| {
            return Break{
                .mandatory = mandatory,
                .i = prev_i,
            };
        }
        before_char = after_char;
        before = after;
        prev_i = self.i;
    }
}

fn checkPair(
    self: *Self,
    before: LineBreakProperty.Value,
    before_char: u32,
    after: LineBreakProperty.Value,
    after_char: u32,
) ?bool {
    return switch (before) {
        .CR => switch (after) {
            .LF => null,
            else => true,
        },
        .BK, .LF, .NL => true,
        .ZW => switch (after) {
            .CR, .BK, .LF, .NL, .ZW => null,
            .SP => self.setContext(.zw_sp),
            else => false,
        },
        .ZWJ => if (self.cm_base) |base| blk: {
            self.cm_base = null;
            break :blk self.checkPair(base.prop, base.char, after, after_char);
        } else null,
        .CM => if (self.cm_base) |base| blk: {
            self.cm_base = null;
            break :blk self.checkPair(base.prop, base.char, after, after_char);
        } else self.checkPair(.AL, undefined, after, after_char),
        .WJ, .GL => switch (after) {
            .CM, .ZWJ => self.setCmBase(before, before_char),
            else => null,
        },
        .BA => switch (after) {
            .GL, .CB => false,
            else => switch (self.context) {
                .hl_hyba => null,
                else => self.defaultAfter(before, before_char, after),
            },
        },
        .OP => switch (after) {
            .SP => self.setContext(.op_sp),
            .CM, .ZWJ => self.setCmBase(before, before_char),
            else => null,
        },
        .QU => switch (after) {
            .SP => self.setContext(.qu_sp),
            .CM, .ZWJ => self.setCmBase(before, before_char),
            else => null,
        },
        .CL => switch (after) {
            .SP => self.setContext(.clcp_sp),
            .NS => null,
            .PR, .PO => if (self.numericBefore()) null else false,
            else => self.defaultAfter(before, before_char, after),
        },
        .CP => switch (after) {
            .SP => self.setContext(.clcp_sp),
            .NS => null,
            .PR, .PO => if (self.numericBefore()) null else false,
            .AL, .HL, .NU => switch (ucd.trieValue(EastAsianWidth, before_char)) {
                .F, .W, .H => self.defaultAfter(before, before_char, after),
                else => null,
            },
            else => self.defaultAfter(before, before_char, after),
        },
        .B2 => switch (after) {
            .SP => self.setContext(.b2_sp),
            .B2 => null,
            else => self.defaultAfter(before, before_char, after),
        },
        .SP => switch (after) {
            .SP => null,
            .BK, .CR, .LF, .NL, .ZW => self.setContext(.none),
            .WJ, .CL, .CP, .EX, .IS, .SY => if (self.context == .zw_sp) false else self.setContext(.none),
            else => switch (self.context) {
                .zw_sp => false,
                .op_sp => self.setContext(.none),
                .qu_sp => if (after == .OP) self.setContext(.none) else false,
                .b2_sp => if (after == .B2) self.setContext(.none) else false,
                .clcp_sp => if (after == .NS) self.setContext(.none) else false,
                else => switch (after) {
                    else => false,
                },
            },
        },
        .CB => switch (after) {
            .BK, .CR, .LF, .NL, .SP, .ZW, .WJ, .GL, .CL, .CP, .EX, .IS, .SY, .QU => null,
            .CM, .ZWJ => self.setCmBase(before, before_char),
            else => false,
        },
        .BB => switch (after) {
            .CM, .ZWJ => self.setCmBase(before, before_char),
            .CB => false,
            else => null,
        },
        .HL => switch (after) {
            .HY, .BA => self.setContext(.hl_hyba),
            .NU, .PR, .PO, .AL, .HL => null,
            .OP => switch (ucd.trieValue(EastAsianWidth, after_char)) {
                .F, .W, .H => self.defaultAfter(before, before_char, after),
                else => null,
            },
            else => self.defaultAfter(before, before_char, after),
        },
        .SY => switch (after) {
            .HL => null,
            .NU => if (self.numericBefore()) null else false,
            else => self.defaultAfter(before, before_char, after),
        },
        .AL => switch (after) {
            .NU, .PR, .PO, .AL, .HL => null,
            .OP => switch (ucd.trieValue(EastAsianWidth, after_char)) {
                .F, .W, .H => self.defaultAfter(before, before_char, after),
                else => null,
            },
            else => self.defaultAfter(before, before_char, after),
        },
        .NU => switch (after) {
            .AL, .HL, .PO, .PR, .NU => null,
            .OP => switch (ucd.trieValue(EastAsianWidth, after_char)) {
                .F, .W, .H => self.defaultAfter(before, before_char, after),
                else => null,
            },
            else => self.defaultAfter(before, before_char, after),
        },
        .PR => switch (after) {
            .ID, .EB, .EM, .AL, .HL, .NU, .JL, .JV, .JT, .H2, .H3 => null,
            .OP => if (self.numericAfter()) null else false,
            else => self.defaultAfter(before, before_char, after),
        },
        .ID => switch (after) {
            .PO => null,
            .EM => blk: {
                break :blk switch (ucd.trieValue(GeneralCategory, before_char)) {
                    .Any => null,
                    else => self.defaultAfter(before, before_char, after),
                };
            },
            else => self.defaultAfter(before, before_char, after),
        },
        .EB => switch (after) {
            .PO, .EM => null,
            else => self.defaultAfter(before, before_char, after),
        },
        .EM => switch (after) {
            .PO => null,
            else => self.defaultAfter(before, before_char, after),
        },
        .PO => switch (after) {
            .AL, .HL, .NU => null,
            .OP => if (self.numericAfter()) null else false,
            else => self.defaultAfter(before, before_char, after),
        },
        .HY => switch (after) {
            .NU => null,
            .GL, .CB => false,
            else => switch (self.context) {
                .hl_hyba => null,
                else => self.defaultAfter(before, before_char, after),
            },
        },
        .IS => switch (after) {
            .NU => if (self.numericBefore()) null else false,
            .AL, .HL => null,
            else => self.defaultAfter(before, before_char, after),
        },
        .JL => switch (after) {
            .JL, .JV, .H2, .H3, .PO => null,
            else => self.defaultAfter(before, before_char, after),
        },
        .JV => switch (after) {
            .JV, .JT, .PO => null,
            else => self.defaultAfter(before, before_char, after),
        },
        .JT => switch (after) {
            .JT, .PO => null,
            else => self.defaultAfter(before, before_char, after),
        },
        .H2 => switch (after) {
            .JV, .JT, .PO => null,
            else => self.defaultAfter(before, before_char, after),
        },
        .H3 => switch (after) {
            .JT, .PO => null,
            else => self.defaultAfter(before, before_char, after),
        },
        .RI => switch (after) {
            .RI => if ((self.ris_count % 2) == 0) false else null,
            else => self.defaultAfter(before, before_char, after),
        },
        else => self.defaultAfter(before, before_char, after),
    };
}

fn setCmBase(self: *Self, before: LineBreakProperty.Value, before_char: u32) ?bool {
    self.cm_base = .{
        .char = before_char,
        .prop = before,
    };
    return null;
}

fn numericBefore(self: *Self) bool {
    var i = self.i - 1;
    while (i > 0) : (i -= 1) {
        switch (prop(self.chars[i - 1])) {
            .SY, .IS => continue,
            .NU => return true,
            else => break,
        }
    }
    return false;
}

fn numericAfter(self: *Self) bool {
    var i = self.i + 1;
    while (i < self.chars.len) : (i += 1) {
        if (prop(self.chars[i]) == .NU) {
            return true;
        }
    }
    return false;
}

fn defaultAfter(self: *Self, before: LineBreakProperty.Value, before_char: u32, after: LineBreakProperty.Value) ?bool {
    return switch (after) {
        .BK, .CR, .LF, .NL, .SP, .ZW, .WJ, .GL, .CL, .CP, .EX, .IS, .SY, .QU, .BA, .HY, .NS, .IN => null,
        .CM, .ZWJ => blk: {
            self.cm_base = .{
                .char = before_char,
                .prop = before,
            };
            break :blk null;
        },
        else => false,
    };
}

fn setContext(self: *Self, context: Context) ?bool {
    self.context = context;
    return null;
}

fn prop(c: u32) LineBreakProperty.Value {
    return switch (ucd.trieValue(LineBreakProperty, c)) {
        .AI, .SG, .XX, .Any => .AL,
        .SA => switch (ucd.trieValue(GeneralCategory, c)) {
            .Mn, .Mc => .CM,
            else => .AL,
        },
        .CJ => .NS,
        else => |v| v,
    };
}

const TestIter = struct {
    iter: Self,

    pub fn init(str: []const u32) TestIter {
        return TestIter{
            .iter = Self.init(str),
        };
    }

    pub fn next(self: *TestIter) ?usize {
        return if (self.iter.next()) |brk|
            brk.i
        else
            null;
    }
};
test {
    try ucd.testBreakIterator("LineBreakTest.txt", TestIter.init);
}
