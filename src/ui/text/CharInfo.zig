const ucd = @import("ucd.zig");
const BidiCategory = @import("ucd/BidiCategory.zig");
const DerivedBidi = @import("ucd/DerivedBidi.zig");

bidi: BidiCategory.Value,

const Self = @This();

pub fn init(c: u32) Self {
    return Self{
        .bidi = switch (ucd.trieValueDecoded(BidiCategory, c)) {
            .Any => normalizeDerivedBidi(c),
            else => |cat| cat,
        },
    };
}

fn normalizeDerivedBidi(c: u32) BidiCategory.Value {
    return switch (ucd.trieValueDecoded(DerivedBidi, c)) {
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
    };
}
