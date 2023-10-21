const std = @import("std");
const chan = @import("../lib.zig").chan;
const def = @import("../lib.zig").def;
const meta = @import("../meta.zig");

pub fn UpdateObject(comptime object: def.ObjectScheme.Object) type {
    const New = NewType(object);
    const Mutate = MutateObject(object);
    return @Type(.{
        .Union = .{
            .layout = .Auto,
            .tag_type = @Type(.{
                .Enum = .{
                    .tag_type = u1,
                    .fields = &[_]std.builtin.Type.EnumField{
                        std.builtin.Type.EnumField{
                            .name = "New",
                            .value = 0,
                        },
                        std.builtin.Type.EnumField{
                            .name = "Mutate",
                            .value = 1,
                        },
                    },
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_exhaustive = true,
                },
            }),
            .fields = &[_]std.builtin.Type.UnionField{
                std.builtin.Type.UnionField{
                    .name = "New",
                    .type = New,
                    .alignment = @alignOf(New),
                },
                std.builtin.Type.UnionField{
                    .name = "Mutate",
                    .type = Mutate,
                    .alignment = @alignOf(Mutate),
                },
            },
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

pub fn NewObject(comptime object: def.ObjectScheme.Object) type {
    var tag_fields: [object.versions.len + 1]std.builtin.Type.EnumField = undefined;
    for (0..object.versions.len) |i| {
        tag_fields[i] = .{
            .name = "V" ++ meta.numFieldName(i + 1),
            .value = i,
        };
    }
    tag_fields[object.versions.len] = .{
        .name = "Unknown",
        .value = object.versions.len,
    };

    var union_fields: [tag_fields.len]std.builtin.Type.UnionField = undefined;
    for (object.versions, 0..) |ver, i| {
        const Type = NewType(ver);
        union_fields[i] = .{
            .name = tag_fields[i].name,
            .type = Type,
            .alignment = @alignOf(Type),
        };
    }
    union_fields[object.versions.len] = .{
        .name = "Unknown",
        .type = void,
        .alignment = @alignOf(void),
    };
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
            .fields = &union_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

pub fn NewType(comptime typ: def.Type) type {
    return switch (typ) {
        .Void => void,
        .Bool => bool,
        .String => []const u8,
        .Int => |info| @Type(.{
            .Int = .{
                .signedness = switch (info.signedness) {
                    .signed => .signed,
                    .bits => info.bits,
                },
            },
        }),
        .Float => |info| @Type(.{
            .Float = .{
                .bits = info.bits,
            },
        }),
        .Optional => |info| @Type(.{
            .Optional = .{
                .child = NewType(info.child.*),
            },
        }),
        .Array => |info| @Type(.{
            .Array = .{
                .len = info.len,
                .child = NewType(info.child.*),
                .sentinel = null,
            },
        }),
        .List => |info| []const NewType(info.child.*),
        .Map => |info| []const struct {
            key: NewType(info.key.*),
            value: NewType(info.value.*),
        },
        .Struct => |info| blk: {
            var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            for (info.fields, 0..) |field, i| {
                const Type = NewType(field.type);
                fields[i] = .{
                    .name = field.name,
                    .type = Type,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(Type),
                };
            }
            break :blk @Type(.{
                .Struct = .{
                    .layout = .Auto,
                    .backing_integer = null,
                    .fields = &fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_tuple = false,
                },
            });
        },
        .Tuple => |info| blk: {
            var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            for (info.fields, 0..) |field, i| {
                const Type = NewType(field);
                fields[i] = .{
                    .name = meta.numFieldName(i),
                    .type = Type,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(Type),
                };
            }
            break :blk @Type(.{
                .Struct = .{
                    .layout = .Auto,
                    .backing_integer = null,
                    .fields = &fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_tuple = true,
                },
            });
        },
        .Union => |info| blk: {
            var tag_fields: [info.fields.len]std.builtin.Type.EnumField = undefined;
            var fields: [info.fields.len]std.builtin.Type.UnionField = undefined;
            for (info.fields, 0..) |field, i| {
                tag_fields[i] = .{
                    .name = field.name,
                    .value = i,
                };

                const Type = NewType(field.type);
                fields[i] = .{
                    .name = field.name,
                    .type = Type,
                    .alignment = @alignOf(Type),
                };
            }
            break :blk @Type(.{
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
                    .fields = &fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                },
            });
        },
        .Enum => |info| blk: {
            var fields: [info.fields.len]std.builtin.Type.EnumField = undefined;
            for (info.fields, 0..) |field, i| {
                fields[i] = .{
                    .name = field.name,
                    .value = i,
                };
            }
            break :blk @Type(.{
                .Enum = .{
                    .tag_type = std.math.IntFittingRange(0, fields.len - 1),
                    .fields = &fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_exhaustive = true,
                },
            });
        },
        .Ref => def.ObjectId,
    };
}

pub fn MutateObject(comptime object: def.ObjectScheme.Object) type {
    var tag_fields: [object.versions.len]std.builtin.Type.EnumField = undefined;
    for (0..object.versions.len) |i| {
        tag_fields[i] = .{
            .name = "V" ++ meta.numFieldName(i + 1),
            .value = i,
        };
    }

    var union_fields: [tag_fields.len]std.builtin.Type.UnionField = undefined;
    for (object.versions, 0..) |ver, i| {
        const Type = MutateType(ver);
        union_fields[i] = .{
            .name = tag_fields[i].name,
            .type = Type,
            .alignment = @alignOf(Type),
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
            .fields = &union_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

pub fn MutateType(comptime typ: def.Type) type {
    return switch (typ) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => NewType(typ),
        .String => []const MutateString,
        .Optional => |info| ?MutateType(info.child.*),
        .Array => |info| []const MutateArray(info),
        .List => |info| []const MutateList(info),
        .Map => |info| []const MutateMap(info),
        .Struct => |info| MutateStruct(info),
        .Tuple => |info| MutateTuple(info),
        .Union => |info| MutateUnion(info),
    };
}

pub const MutateString = union(enum) {
    Append: []const u8,
    Prepend: []const u8,
    Insert: struct {
        at: usize,
        str: []const u8,
    },
    Delete: struct {
        at: usize,
        len: usize,
    },
};

pub fn MutateArray(comptime info: def.Type.Array) type {
    return struct {
        at: usize,
        mut: MutateType(info.child.*),
    };
}

pub fn MutateList(comptime info: def.Type.List) type {
    return union(enum) {
        Append: NewType(info.child.*),
        Prepend: NewType(info.child.*),
        Insert: struct {
            at: usize,
            elem: NewType(info.child.*),
        },
        Delete: usize,
        Mutate: struct {
            at: usize,
            elem: MutateType(info.child.*),
        },
    };
}

pub fn MutateMap(comptime info: def.Type.Map) type {
    return union(enum) {
        Put: struct {
            key: NewType(info.key.*),
            value: NewType(info.value.*),
        },
        Remove: NewType(info.key.*),
        Mutate: struct {
            key: NewType(info.key.*),
            value: MutateType(info.value.*),
        },
    };
}

pub fn MutateStruct(comptime info: def.Type.Struct) type {
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    for (info.fields, 0..) |field, i| {
        const Type = ?MutateType(field.type);
        fields[i] = .{
            .name = field.name,
            .type = Type,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(Type),
        };
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

pub fn MutateTuple(comptime info: def.Type.Tuple) type {
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    for (info.fields, 0..) |field, i| {
        const Type = ?MutateType(field);
        fields[i] = .{
            .name = meta.numFieldName(i),
            .type = Type,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(Type),
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

pub fn MutateUnion(comptime info: def.Type.Union) type {
    var tag_fields: [info.fields.len]std.builtin.Type.EnumField = undefined;
    var fields: [info.fields.len]std.builtin.Type.UnionField = undefined;
    for (info.fields, 0..) |field, i| {
        tag_fields[i] = .{
            .name = field.name,
            .value = i,
        };

        const Type = union(enum) {
            New: NewType(field.type),
            Mutate: MutateType(field.type),
        };
        fields[i] = .{
            .name = field.name,
            .type = Type,
            .alignment = @alignOf(Type),
        };
    }
    return @Type(.{
        .layout = .Auto,
        .tag_type = @Type(.{
            .Enum = .{
                .tag_type = std.math.IntFittingRange(0, tag_fields.len - 1),
                .fields = &tag_fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_exhaustive = true,
            },
        }),
        .fields = &fields,
        .decls = &[_]std.builtin.Type.Declaration{},
    });
}
