const std = @import("std");

pub fn mergeTypes(comptime left: []const type, comptime right: []const type) []const type {
    comptime {
        var result = left;
        outer: for (right) |Right| {
            for (left) |Left| {
                if (Left == Right)
                    continue :outer;
            }
            result = result ++ &[_]type{Right};
        }
        return result;
    }
}

pub fn Tuple(comptime types: anytype) type {
    comptime {
        var fields: [types.len]std.builtin.Type.StructField = undefined;
        for (types, 0..) |T, i| {
            fields[i] = .{
                .name = numFieldName(i),
                .type = T,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(T),
            };
        }
        return @Type(.{
            .Struct = .{
                .layout = .Auto,
                .backing_integer = null,
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_tuple = true,
            },
        });
    }
}

pub fn NumEnum(comptime num: comptime_int) type {
    comptime {
        var fields: [num]std.builtin.Type.EnumField = undefined;
        for (0..num) |i| {
            fields[i] = .{
                .name = numFieldName(i),
                .value = i,
            };
        }
        return @Type(.{
            .Enum = .{
                .tag_type = std.math.IntFittingRange(0, num - 1),
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_exhaustive = true,
            },
        });
    }
}

pub fn numFieldName(comptime num: comptime_int) []const u8 {
    comptime {
        var field_name_size = std.fmt.count("{d}", .{num});
        var field_name: [field_name_size]u8 = undefined;
        _ = std.fmt.formatIntBuf(&field_name, num, 10, .lower, .{});
        return &field_name;
    }
}
