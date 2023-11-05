const std = @import("std");
const def = @import("../lib.zig").def;
const meta = @import("../meta.zig");

pub const IndexId = struct {
    scheme: u16,
    type: u16,
};

pub fn Index(comptime schemes: anytype) type {
    return struct {
        pub const infos = blk: {
            var result: [schemes.len]def.ObjectScheme = undefined;
            for (schemes, 0..) |Scheme, i| {
                result[i] = def.ObjectScheme.from(Scheme);
                for (result[0..i]) |prev_scheme| {
                    if (std.mem.eql(u8, result[i].name, prev_scheme.name)) {
                        @compileError("duplicate object schemes found: " ++ prev_scheme.name);
                    }
                }
            }
            break :blk result;
        };

        pub fn Object(comptime id: IndexId) type {
            return schemes[id.scheme].types[id.type];
        }

        pub fn objectId(comptime ObjectRef: type) IndexId {
            if (Object.def_kind != .ref or Object.def.def_kind != .object) {
                @compileError("Object must be an object ref type");
            }
            for (schemes, 0..) |Scheme, i| {
                if (Scheme == ObjectRef.scheme) {
                    for (Scheme.refs, 0..) |Ref, ii| {
                        if (Ref == ObjectRef) {
                            return IndexId{
                                .scheme = i,
                                .type = ii,
                            };
                        }
                    }
                }
            }
            @compileError("Object not found");
        }
    };
}
