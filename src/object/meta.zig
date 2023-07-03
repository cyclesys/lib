const std = @import("std");
const meta = @import("../meta.zig");
const definition = @import("../definition.zig");

pub usingnamespace meta;

pub fn FieldTypeEnum(comptime fields: []const definition.FieldType.EnumField) type {
    var enum_fields: [fields.len]std.builtin.Type.EnumField = undefined;
    for (fields, 0..) |field, i| {
        enum_fields[i] = .{
            .name = field.name,
            .value = i,
        };
    }
    return @Type(.{
        .Enum = .{
            .tag_type = std.math.IntFittingRange(0, fields.len - 1),
            .fields = &enum_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_exhaustive = true,
        },
    });
}

pub fn verFieldName(comptime num: comptime_int) []const u8 {
    comptime {
        return "v" ++ meta.numFieldName(num + 1);
    }
}
