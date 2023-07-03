const std = @import("std");
const SharedMem = @import("SharedMem.zig");

pub const channel = @import("object/channel.zig");
pub const index = @import("object/index.zig");
pub const read = @import("object/read.zig");
pub const write = @import("object/write.zig");

pub const TypeId = struct {
    scheme: u16,
    name: u32,
};

pub const ObjectId = packed struct(u64) {
    scheme: u16,
    source: u16,
    name: u32,
};

pub const Object = struct {
    type: TypeId,
    id: ObjectId,
    mem: SharedMem,
};

test {
    _ = @import("object/index.zig");
    _ = @import("object/read.zig");
    _ = @import("object/write.zig");
}
