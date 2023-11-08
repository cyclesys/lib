const std = @import("std");
const def = @import("../lib.zig").def;
const meta = @import("../meta.zig");

pub fn Index(comptime scheme_types: anytype) type {
    return struct {
        pub const schemes = scheme_types;

        pub const infos = blk: {
            var result: [scheme_types.len]def.ObjectScheme = undefined;
            for (scheme_types, 0..) |Scheme, i| {
                result[i] = def.ObjectScheme.from(Scheme);
                for (result[0..i]) |prev_scheme| {
                    if (std.mem.eql(u8, result[i].name, prev_scheme.name)) {
                        @compileError("duplicate object schemes found: " ++ prev_scheme.name);
                    }
                }
            }
            break :blk result;
        };

        pub fn Type(comptime id: def.TypeId) type {
            return scheme_types[id.scheme].types[id.name].versions[id.version];
        }

        pub fn typeId(comptime ObjectRef: type, comptime version: comptime_int) def.TypeId {
            if (ObjectRef.def_kind != .ref or ObjectRef.def.def_kind != .object) {
                @compileError("Object must be an object ref type");
            }

            if (version < 0 or version >= ObjectRef.def.versions.len) {
                @compileError("Object version number is invalid");
            }

            for (scheme_types, 0..) |Scheme, i| {
                if (Scheme == ObjectRef.scheme) {
                    for (Scheme.types, 0..) |T, ii| {
                        if (T == ObjectRef.def) {
                            return def.TypeId{
                                .scheme = i,
                                .type = ii,
                                .version = version,
                            };
                        }
                    }
                }
            }
            @compileError("Object not found");
        }
    };
}
