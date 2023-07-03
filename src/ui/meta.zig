const std = @import("std");
pub usingnamespace @import("../meta.zig");

pub fn opt(opts: anytype, comptime name: anytype) OptType(@TypeOf(opts), name) {
    const Opt = OptType(@TypeOf(opts), name);
    if (Opt == void) {
        return null;
    } else {
        return @field(opts, @tagName(name));
    }
}

fn OptType(comptime Opts: type, comptime name: anytype) type {
    if (@hasField(Opts, name)) {
        const Type = std.meta.FieldType(Opts, name);
        if (@typeInfo(Type) == .Optional) {
            return Type;
        }

        return ?Type;
    }
    return ?void;
}

pub fn initMerge(comptime Expected: type, actual: anytype) Merge(Expected, @TypeOf(actual)) {
    const Actual = @TypeOf(actual);
    var result: Merge(Expected, Actual) = undefined;
    return result;
}

pub fn Merge(comptime Expected: type, comptime Actual: type) type {
    const exp_info = @typeInfo(Expected).Struct;
    var out_fields: [exp_info.fields.len]std.builtin.Type.StructField = undefined;
    var out_len = 0;
    for (exp_info.fields) |exp_field| {
        if (@hasField(Actual, exp_field.name)) {
            var exp_is_optional = false;
            var exp_field_type: type = exp_field.type;
            if (@typeInfo(exp_field_type) == .Optional) {
                exp_is_optional = true;
                exp_field_type = @typeInfo(exp_field_type).Optional.child;
            }

            var act_is_optional = false;
            var act_field_type = FieldType(Actual, exp_field.name);
            if (@typeInfo(act_field_type) == .Optional) {
                if (!exp_is_optional) {
                    @compileError("");
                }

                act_is_optional = true;
                act_field_type = @typeInfo(act_field_type).Optional.child;
            }

            var out_field_type: type = exp_field_type;
            if (@typeInfo(exp_field_type) == .Struct) {
                out_field_type = Merge(exp_field_type, act_field_type);
            }

            if (act_is_optional) {
                out_field_type = ?out_field_type;
            }

            out_fields[out_len] = .{
                .name = exp_field.name,
                .type = out_field_type,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(out_field_type),
            };
            out_len += 1;
        } else if (@typeInfo(exp_field.type) != .Optional) {
            @compileError("");
        }
    }

    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .backing_integer = null,
            .fields = out_fields[0..out_len],
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

pub fn FieldType(comptime T: type, comptime name: []const u8) type {
    return std.meta.FieldType(T, @enumFromInt(
        std.meta.fieldIndex(T, name),
    ));
}
