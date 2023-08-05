const ucd = @import("ucd.zig");
const BidiCategory = @import("ucd/BidiCategory.zig");

bidi: BidiCategory.Value,

pub fn init(c: u32) @This() {
    return .{
        .bidi_cat = ucd.trieValue(BidiCategory, c),
    };
}
