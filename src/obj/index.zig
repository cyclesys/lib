const std = @import("std");
const def = @import("../lib.zig").def;
const meta = @import("../meta.zig");
const id = @import("id.zig");

pub fn Index(comptime scheme_types: anytype) type {
    return struct {
        pub const schemes = scheme_types;

        pub const infos: []const def.ObjectScheme = blk: {
            var result: [scheme_types.len]def.ObjectScheme = undefined;
            for (scheme_types, 0..) |Scheme, i| {
                result[i] = def.ObjectScheme.from(Scheme);
                for (result[0..i]) |prev_scheme| {
                    if (std.mem.eql(u8, result[i].name, prev_scheme.name)) {
                        @compileError("duplicate object schemes found: " ++ prev_scheme.name);
                    }
                }
            }
            break :blk result[0..];
        };

        pub const ids: []const id.SchemeIdInt = blk: {
            var result: []const id.SchemeIdInt = undefined;
            for (scheme_types, 0..) |Scheme, scheme_id| {
                for (Scheme.types, 0..) |Object, object_id| {
                    var new_ids: [Object.versions.len]id.SchemeIdInt = undefined;
                    for (0..Object.versions.len) |version_id| {
                        new_ids[version_id] = @bitCast(id.SchemeId{
                            .scheme = scheme_id,
                            .path = object_id,
                            .value = version_id,
                        });
                    }
                    result = result ++ &new_ids;
                }
            }
            break :blk result;
        };

        pub fn Type(comptime type_id: def.SchemeId) type {
            return scheme_types[type_id.scheme].types[type_id.path].versions[type_id.value];
        }

        pub fn typeId(comptime ObjectRef: type, comptime version: comptime_int) def.SchemeId {
            if (ObjectRef.def_kind != .ref or ObjectRef.def.def_kind != .object) {
                @compileError("Object must be an object ref type");
            }

            if (version < 0 or version >= ObjectRef.def.versions.len) {
                @compileError("Object version number is invalid");
            }

            for (scheme_types, 0..) |Scheme, scheme_id| {
                if (Scheme == ObjectRef.scheme) {
                    for (Scheme.types, 0..) |T, object_id| {
                        if (T == ObjectRef.def) {
                            return def.SchemeId{
                                .scheme = scheme_id,
                                .path = object_id,
                                .value = version,
                            };
                        }
                    }
                }
            }
            @compileError("Object not found");
        }
    };
}
