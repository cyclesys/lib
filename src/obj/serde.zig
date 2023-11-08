const std = @import("std");
const chan = @import("../lib.zig").chan;
const def = @import("../lib.zig").def;
const meta = @import("../meta.zig");
const idx = @import("index.zig");

pub fn UpdateObject(comptime ObjectRef: type) type {
    const Object = ObjectRef.def;
    const New = NewObject(Object);
    const Mutate = MutateObject(Object);
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

pub fn NewObject(comptime Object: type) type {
    return ObjectVersions(Object, NewType);
}

pub fn NewType(comptime Type: type) type {
    return switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum => Type,
        .String => NewString,
        .Optional => NewOptional(Type),
        .Array => NewArray(Type),
        .List => NewList(Type),
        .Map => NewMap(Type),
        .Struct => NewStruct(Type),
        .Tuple => NewTuple(Type),
        .Union => NewUnion(Type),
        .Ref => u128,
    };
}

pub const NewString = []const u8;

pub fn NewOptional(comptime Type: type) type {
    return ?NewType(std.meta.Child(Type));
}

pub fn NewArray(comptime Type: type) type {
    return [Type.len]NewType(Type.child);
}

pub fn NewList(comptime Type: type) type {
    return []const NewType(Type.child);
}

pub fn NewMap(comptime Type: type) type {
    return []const NewMapEntry(Type);
}

pub fn NewMapEntry(comptime Type: type) type {
    return struct {
        key: NewType(Type.key),
        value: NewType(Type.value),
    };
}

pub fn NewStruct(comptime Type: type) type {
    return Struct(Type, NewType);
}

pub fn NewTuple(comptime Type: type) type {
    return Tuple(Type, NewType);
}

pub fn NewUnion(comptime Type: type) type {
    return Union(Type, NewType);
}

pub fn MutateObject(comptime Object: type) type {
    return ObjectVersions(Object, MutateType);
}

pub fn MutateType(comptime Type: type) type {
    return switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => NewType(Type),
        .String => MutateString,
        .Optional => MutateOptional(Type),
        .Array => MutateArray(Type),
        .List => MutateList(Type),
        .Map => MutateMap(Type),
        .Struct => MutateStruct(Type),
        .Tuple => MutateTuple(Type),
        .Union => MutateUnion(Type),
    };
}

pub const MutateString = []const MutateStringOp;

pub const MutateStringOp = union(enum) {
    Append: []const u8,
    Prepend: []const u8,
    Insert: InsertOp,
    Delete: DeleteOp,

    pub const InsertOp = struct {
        index: u64,
        str: []const u8,
    };

    pub const DeleteOp = struct {
        index: u64,
        len: u64,
    };
};

pub fn MutateOptional(comptime Type: type) type {
    return union(enum) {
        New: NewType(Type),
        Mutate: MutateType(Type),
        Null: void,
    };
}

pub fn MutateArray(comptime Type: type) type {
    return []const MutateArrayOp(Type);
}

pub fn MutateArrayOp(comptime Type: type) type {
    return struct {
        index: u64,
        elem: MutateType(Type.child),
    };
}

pub fn MutateList(comptime Type: type) type {
    return []const MutateListOp(Type);
}

pub fn MutateListOp(comptime Type: type) type {
    return union(enum) {
        Append: NewType(Type.child),
        Prepend: NewType(Type.child),
        Insert: struct {
            index: u64,
            elem: NewType(Type.child),
        },
        Delete: u64,
        Mutate: struct {
            index: u64,
            elem: MutateType(Type.child),
        },
    };
}

pub fn MutateMap(comptime Type: type) type {
    return []const MutateMapOp(Type);
}

pub fn MutateMapOp(comptime Type: type) type {
    return union(enum) {
        Put: NewMapEntry(Type),
        Remove: NewType(Type.key),
        Mutate: MutateMapEntry(Type),
    };
}

pub fn MutateMapEntry(comptime Type: type) type {
    return struct {
        key: NewType(Type.key),
        value: MutateType(Type.value),
    };
}

pub fn MutateStruct(comptime Type: type) type {
    return Struct(Type, OptMutateType);
}

pub fn MutateTuple(comptime Type: type) type {
    return Tuple(Type, OptMutateType);
}

fn OptMutateType(comptime Type: type) type {
    return ?MutateType(Type);
}

pub fn MutateUnion(comptime Type: type) type {
    return Union(Type, MutateUnionField);
}

pub fn MutateUnionField(comptime Type: type) type {
    return union(enum) {
        New: NewType(Type),
        Mutate: MutateType(Type),
    };
}

fn ObjectVersions(comptime Object: type, comptime Field: fn (type) type) type {
    var tag_fields: [Object.versions.len]std.builtin.Type.EnumField = undefined;
    var fields: [tag_fields.len]std.builtin.Type.UnionField = undefined;
    for (Object.versions, 0..) |Ver, i| {
        tag_fields[i] = .{
            .name = "v" ++ meta.numFieldName(i),
            .value = i,
        };

        const FieldType = Field(Ver);
        fields[i] = .{
            .name = tag_fields[i].name,
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
            .fields = &fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

fn Struct(comptime Type: type, comptime Field: fn (type) type) type {
    return meta.RemapStruct(meta.fields(Type), Field);
}

fn Tuple(comptime Type: type, comptime Field: fn (type) type) type {
    return meta.RemapTuple(meta.fields(Type), Field);
}

fn Union(comptime Type: type, comptime Field: fn (type) type) type {
    return meta.RemapUnion(meta.fields(Type), Field);
}
