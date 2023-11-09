const std = @import("std");
const def = @import("lib.zig").def;

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
        var struct_fields: [types.len]std.builtin.Type.StructField = undefined;
        for (types, 0..) |T, i| {
            struct_fields[i] = .{
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
                .fields = &struct_fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_tuple = true,
            },
        });
    }
}

pub fn NumEnum(comptime num: comptime_int) type {
    comptime {
        var enum_fields: [num]std.builtin.Type.EnumField = undefined;
        for (0..num) |i| {
            enum_fields[i] = .{
                .name = numFieldName(i),
                .value = i,
            };
        }
        return @Type(.{
            .Enum = .{
                .tag_type = std.math.IntFittingRange(0, num - 1),
                .fields = &enum_fields,
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

pub fn fields(comptime Type: type) switch (@typeInfo(Type)) {
    .Struct => []const std.builtin.Type.StructField,
    .Union => []const std.builtin.Type.UnionField,
    else => @compileError("unsupported"),
} {
    return switch (@typeInfo(Type)) {
        .Struct => |info| blk: {
            var out_fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            var len = 0;
            for (info.fields) |f| {
                if (def.Type.from(f.type) == null) continue;
                out_fields[len] = f;
                len += 1;
            }
            break :blk out_fields[0..len];
        },
        .Union => |info| blk: {
            var out_fields: [info.fields.len]std.builtin.Type.UnionField = undefined;
            var len = 0;
            for (info.fields) |f| {
                if (def.Type.from(f.type) == null) continue;
                out_fields[len] = f;
                len += 1;
            }
            break :blk out_fields[0..len];
        },
        else => @compileError("unsupported"),
    };
}

pub fn RemapStruct(comptime in_fields: []const std.builtin.Type.StructField, comptime Remap: fn (comptime type) type) type {
    var out_fields: [in_fields.len]std.builtin.Type.StructField = undefined;
    for (in_fields, 0..) |f, i| {
        const FieldType = Remap(f.type);
        out_fields[i] = .{
            .name = f.name,
            .type = FieldType,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(FieldType),
        };
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .backing_integer = null,
            .fields = &out_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

pub fn RemapTuple(comptime in_fields: []const std.builtin.Type.StructField, comptime Remap: fn (comptime type) type) type {
    var out_fields: [in_fields.len]std.builtin.Type.StructField = undefined;
    for (in_fields, 0..) |f, i| {
        const FieldType = Remap(f.type);
        out_fields[i] = .{
            .name = numFieldName(i),
            .type = FieldType,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(FieldType),
        };
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .backing_integer = null,
            .fields = &out_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = true,
        },
    });
}

pub fn RemapUnion(comptime in_fields: []const std.builtin.Type.UnionField, comptime Remap: fn (comptime type) type) type {
    var tag_fields: [in_fields.len]std.builtin.Type.EnumField = undefined;
    var out_fields: [in_fields.len]std.builtin.Type.UnionField = undefined;
    for (in_fields, 0..) |f, i| {
        tag_fields[i] = .{
            .name = f.name,
            .value = i,
        };

        const FieldType = Remap(f.type);
        out_fields[i] = .{
            .name = f.name,
            .type = FieldType,
            .alignment = @alignOf(FieldType),
        };
    }
    return @Type(.{
        .Union = .{
            .layout = .Auto,
            .tag_type = @Type(.{
                .Enum = .{
                    .tag_type = std.math.IntFittingRange(0, tag_fields.len - 1),
                    .fields = &tag_fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_exhaustive = true,
                },
            }),
            .fields = &out_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}
