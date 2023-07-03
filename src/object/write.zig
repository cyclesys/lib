const std = @import("std");
const definition = @import("../definition.zig");
const serde = @import("../serde.zig");
const super = @import("../object.zig");
const meta = @import("meta.zig");

fn VersionEnum(comptime len: comptime_int) type {
    comptime {
        var fields: [len]std.builtin.Type.EnumField = undefined;
        for (0..len) |i| {
            fields[i] = .{
                .name = meta.verFieldName(i),
                .value = i,
            };
        }
        return @Type(.{
            .Enum = .{
                .tag_type = std.math.IntFittingRange(0, len - 1),
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_exhaustive = true,
            },
        });
    }
}

pub fn ObjectValue(comptime Obj: type) type {
    comptime {
        const len = Obj.def.versions.len;
        var fields: [len]std.builtin.Type.UnionField = undefined;
        for (Obj.def.versions, 0..) |Version, i| {
            const info = definition.FieldType.from(Version).?;
            const VersionValue = FieldTypeValue(info);
            fields[i] = .{
                .name = meta.verFieldName(i),
                .type = VersionValue,
                .alignment = @alignOf(VersionValue),
            };
        }
        return @Type(.{
            .Union = .{
                .layout = .Auto,
                .tag_type = VersionEnum(len),
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
            },
        });
    }
}

fn FieldTypeValue(comptime info: definition.FieldType) type {
    return switch (info) {
        .Void => void,
        .Bool => bool,
        .Int => |int_info| @Type(.{ .Int = int_info }),
        .Float => |float_info| @Type(.{ .Float = float_info }),
        .Optional => |child_info| ?FieldTypeValue(child_info.*),
        .Ref => super.ObjectId,
        .Array => |array_info| [array_info.len]FieldTypeValue(array_info.child.*),
        .List => |child_info| std.ArrayList(FieldTypeValue(child_info.*)),
        .Map => |map_info| std.ArrayList(struct {
            key: FieldTypeValue(map_info.key.*),
            value: FieldTypeValue(map_info.value.*),
        }),
        .String => []const u8,
        .Struct => |fields| StructValue(fields),
        .Tuple => |fields| TupleValue(fields),
        .Union => |fields| UnionValue(fields),
        .Enum => |fields| meta.FieldTypeEnum(fields),
    };
}

fn StructValue(comptime fields: []const definition.FieldType.StructField) type {
    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;
    for (fields, 0..) |field, i| {
        const FieldType = FieldTypeValue(field.type);
        struct_fields[i] = .{
            .name = field.name,
            .type = FieldType,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(?FieldType),
        };
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .backing_integer = null,
            .fields = &struct_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

fn TupleValue(comptime fields: []const definition.FieldType) type {
    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;
    for (fields, 0..) |field, i| {
        const FieldType = FieldTypeValue(field);
        struct_fields[i] = .{
            .name = meta.numFieldName(i),
            .type = ?FieldType,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(?FieldType),
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

fn UnionValue(comptime fields: []const definition.FieldType.UnionField) type {
    var enum_fields: [fields.len]std.builtin.Type.EnumField = undefined;
    var union_fields: [fields.len]std.builtin.Type.UnionField = undefined;
    for (fields, 0..) |field, i| {
        enum_fields[i] = .{
            .name = field.name,
            .value = i,
        };

        const FieldType = FieldTypeValue(field.type);
        union_fields[i] = .{
            .name = field.name,
            .type = FieldType,
            .alignment = @alignOf(FieldType),
        };
    }
    return @Type(.{
        .Union = .{
            .layout = .Auto,
            .tag_type = @Type(.{
                .Enum = .{
                    .tag_type = std.math.IntFittingRange(0, fields.len - 1),
                    .fields = &enum_fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_exhaustive = true,
                },
            }),
            .fields = &union_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

pub fn writeValue(comptime Obj: type, value: ObjectValue(Obj), writer: anytype) !void {
    switch (value) {
        inline else => |val, tag| {
            const version = @intFromEnum(tag);
            try serde.serialize(@as(usize, version), writer);

            const Version = Obj.def.versions[version];

            const info = comptime definition.FieldType.from(Version).?;
            try writeFieldTypeValue(info, val, writer);
        },
    }
}

fn writeFieldTypeValue(comptime info: definition.FieldType, value: anytype, writer: anytype) !void {
    switch (info) {
        .Void => {},
        .Bool, .Int, .Float, .Ref, .String, .Enum => {
            try serde.serialize(value, writer);
        },
        .Optional => |child_info| {
            if (value) |v| {
                try writer.writeByte(1);
                try writeFieldTypeValue(child_info.*, v, writer);
            } else {
                try writer.writeByte(0);
            }
        },
        .Array => |array_info| {
            for (value) |v| {
                try writeFieldTypeValue(array_info.child.*, v, writer);
            }
        },
        .List => |child_info| {
            try serde.serialize(value.items.len, writer);
            for (value.items) |v| {
                try writeFieldTypeValue(child_info.*, v, writer);
            }
        },
        .Map => |map_info| {
            try serde.serialize(value.items.len, writer);
            for (value.items) |v| {
                try writeFieldTypeValue(map_info.key.*, v.key, writer);
                try writeFieldTypeValue(map_info.value.*, v.value, writer);
            }
        },
        .Struct => |fields| {
            inline for (fields) |field| {
                try writeFieldTypeValue(field.type, @field(value, field.name), writer);
            }
        },
        .Tuple => |fields| {
            inline for (fields, 0..) |field, i| {
                try writeFieldTypeValue(field, value[i], writer);
            }
        },
        .Union => |fields| {
            switch (value) {
                inline else => |val, tag| {
                    const field = fields[@intFromEnum(tag)];
                    try writeFieldTypeValue(field.type, val, writer);
                },
            }
        },
    }
}

pub fn ObjectMut(comptime Obj: type) type {
    comptime {
        const len = Obj.def.versions.len;
        var fields: [len]std.builtin.Type.UnionField = undefined;
        for (Obj.def.versions, 0..) |Version, i| {
            const info = definition.FieldType.from(Version).?;
            const VersionMut = FieldTypeMut(info);
            fields[i] = .{
                .name = meta.verFieldName(i),
                .type = VersionMut,
                .alignment = @alignOf(VersionMut),
            };
        }
        return @Type(.{
            .Union = .{
                .layout = .Auto,
                .tag_type = VersionEnum(len),
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
            },
        });
    }
}

fn FieldTypeMut(comptime info: definition.FieldType) type {
    return switch (info) {
        .Void => void,
        .Bool => bool,
        .Int => |int_info| @Type(.{ .Int = int_info }),
        .Float => |float_info| @Type(.{ .Float = float_info }),
        .Optional => |child_info| OptionalMut(child_info.*),
        .Ref => super.ObjectId,
        .Array => |array_info| ArrayMut(array_info),
        .List => |child_info| ListMut(child_info.*),
        .Map => |map_info| MapMut(map_info),
        .String => []const u8,
        .Struct => |fields| StructMut(fields),
        .Tuple => |fields| TupleMut(fields),
        .Union => |fields| UnionMut(fields),
        .Enum => |fields| meta.FieldTypeEnum(fields),
    };
}

fn OptionalMut(comptime child_info: definition.FieldType) type {
    return struct {
        value: ?FieldTypeMut(child_info),
    };
}

fn ArrayMut(comptime info: definition.FieldType.Array) type {
    comptime {
        const FieldType = FieldTypeMut(info.child.*);
        const default_value: ?FieldType = null;

        var fields: [info.len]std.builtin.Type.StructField = undefined;
        for (0..info.len) |i| {
            fields[i] = .{
                .name = meta.numFieldName(i),
                .type = ?FieldType,
                .default_value = @ptrCast(&default_value),
                .is_comptime = false,
                .alignment = @alignOf(?FieldType),
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

fn ListMut(comptime child_info: definition.FieldType) type {
    return struct {
        inner: Inner,

        const Inner = std.ArrayList(Item);
        const Item = union(enum) {
            Append: Value,
            Pop: void,
            Insert: struct {
                idx: usize,
                value: Value,
            },
            Remove: usize,
            Set: struct {
                idx: usize,
                value: Value,
            },
            Mut: struct {
                idx: usize,
                mut: ValueMut,
            },
        };
        pub const Value = FieldTypeValue(child_info);
        pub const ValueMut = FieldTypeMut(child_info);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .inner = Inner.init(allocator),
            };
        }

        pub fn append(self: *Self, value: Value) !void {
            try self.inner.append(.{
                .Append = value,
            });
        }

        pub fn pop(self: *Self) !void {
            try self.inner.append(.Pop);
        }

        pub fn insert(self: *Self, idx: usize, value: Value) !void {
            try self.inner.append(.{
                .Insert = .{
                    .idx = idx,
                    .value = value,
                },
            });
        }

        pub fn remove(self: *Self, idx: usize) !void {
            try self.inner.append(.{
                .Remove = idx,
            });
        }

        pub fn set(self: *Self, idx: usize, value: Value) !void {
            try self.inner.append(.{
                .Set = .{
                    .idx = idx,
                    .value = value,
                },
            });
        }

        pub fn mut(self: *Self, idx: usize, m: ValueMut) !void {
            try self.inner.append(.{
                .Mut = .{
                    .idx = idx,
                    .mut = m,
                },
            });
        }
    };
}

fn MapMut(comptime info: definition.FieldType.Map) type {
    return struct {
        inner: Inner,

        const Inner = std.ArrayList(Item);
        const Item = union(enum) {
            Put: KeyValue,
            PutNoClobber: KeyValue,
            Remove: Key,
            Swap: struct {
                old: Key,
                new: Key,
            },
            MutKey: struct {
                key: Key,
                mut: KeyMut,
            },
            MutValue: struct {
                key: Key,
                value: ValueMut,
            },
        };
        const KeyValue = struct {
            key: Key,
            value: Value,
        };
        pub const Key = FieldTypeValue(info.key.*);
        pub const KeyMut = FieldTypeMut(info.key.*);
        pub const Value = FieldTypeValue(info.value.*);
        pub const ValueMut = FieldTypeMut(info.value.*);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .inner = Inner.init(allocator),
            };
        }

        pub fn put(self: *Self, key: Key, value: Value) !void {
            try self.inner.append(.{
                .PutClobber = .{
                    .key = key,
                    .value = value,
                },
            });
        }

        pub fn putNoClobber(self: *Self, key: Key, value: Value) !void {
            try self.inner.append(.{
                .PutNoClobber = .{
                    .key = key,
                    .value = value,
                },
            });
        }

        pub fn remove(self: *Self, key: Key) !void {
            try self.inner.append(.{
                .Remove = key,
            });
        }

        pub fn swap(self: *Self, old: Key, new: Key) !void {
            try self.inner.append(.{
                .Swap = .{
                    .old = old,
                    .new = new,
                },
            });
        }

        pub fn mutKey(self: *Self, key: Key, mut: KeyMut) !void {
            try self.inner.append(.{
                .MutKey = .{
                    .key = key,
                    .mut = mut,
                },
            });
        }

        pub fn mutValue(self: *Self, key: Key, value: ValueMut) !void {
            try self.inner.append(.{
                .MutValue = .{
                    .key = key,
                    .value = value,
                },
            });
        }
    };
}

fn StructMut(comptime fields: []const definition.FieldType.StructField) type {
    comptime {
        var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;
        for (fields, 0..) |field, i| {
            const FieldType = FieldTypeMut(field.type);
            const default_value: ?FieldType = null;
            struct_fields[i] = .{
                .name = field.name,
                .type = ?FieldType,
                .default_value = @ptrCast(&default_value),
                .is_comptime = false,
                .alignment = @alignOf(?FieldType),
            };
        }
        return @Type(.{
            .Struct = .{
                .layout = .Auto,
                .backing_integer = null,
                .fields = &struct_fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_tuple = false,
            },
        });
    }
}

fn TupleMut(comptime fields: []const definition.FieldType) type {
    comptime {
        var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;
        for (fields, 0..) |field, i| {
            const FieldType = FieldTypeMut(field);
            const default_value: ?FieldType = null;
            struct_fields[i] = .{
                .name = meta.numFieldName(i),
                .type = ?FieldType,
                .default_value = @ptrCast(&default_value),
                .is_comptime = false,
                .alignment = @alignOf(?FieldType),
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

fn UnionMut(comptime fields: []const definition.FieldType.UnionField) type {
    var enum_fields: [fields.len]std.builtin.Type.EnumField = undefined;
    var union_fields: [fields.len]std.builtin.Type.UnionField = undefined;
    for (fields, 0..) |field, i| {
        enum_fields[i] = .{
            .name = field.name,
            .value = i,
        };

        const FieldType = FieldTypeMut(field.type);
        union_fields[i] = .{
            .name = field.name,
            .type = FieldType,
            .alignment = @alignOf(FieldType),
        };
    }
    return @Type(.{
        .Union = .{
            .layout = .Auto,
            .tag_type = @Type(.{
                .Enum = .{
                    .tag_type = std.math.IntFittingRange(0, fields.len - 1),
                    .fields = &enum_fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_exhaustive = true,
                },
            }),
            .fields = &union_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });
}

pub fn writeMut(comptime Obj: type, mut: ObjectMut(Obj), writer: anytype) !void {
    switch (mut) {
        inline else => |val, tag| {
            const version = @intFromEnum(tag);
            try serde.serialize(@as(usize, version), writer);

            const Version = Obj.def.versions[version];

            const info = comptime definition.FieldType.from(Version).?;
            try writeFieldTypeMut(info, val, writer);
        },
    }
}

fn writeFieldTypeMut(comptime info: definition.FieldType, mut: anytype, writer: anytype) !void {
    switch (info) {
        .Void => {},
        .Bool, .Int, .Float, .Ref, .String, .Enum => {
            try serde.serialize(mut, writer);
        },
        .Optional => |child_info| {
            if (mut.value) |v| {
                try writer.writeByte(1);
                try writeFieldTypeMut(child_info.*, v, writer);
            } else {
                try writer.writeByte(0);
            }
        },
        .Array => |array_info| {
            inline for (mut) |value| {
                if (value) |v| {
                    try writer.writeByte(1);
                    try writeFieldTypeMut(array_info.child.*, v, writer);
                } else {
                    try writer.writeByte(0);
                }
            }
        },
        .List => |child_info| {
            try serde.serialize(mut.inner.items.len, writer);
            for (mut.inner.items) |item| {
                try serde.serialize(@intFromEnum(item), writer);
                switch (item) {
                    .Append => |value| {
                        try writeFieldTypeValue(child_info.*, value, writer);
                    },
                    .Pop => {},
                    .Insert => |ins| {
                        try serde.serialize(ins.idx, writer);
                        try writeFieldTypeValue(child_info.*, ins.value, writer);
                    },
                    .Remove => |idx| {
                        try serde.serialize(idx, writer);
                    },
                    .Set => |set| {
                        try serde.serialize(set.idx, writer);
                        try writeFieldTypeValue(child_info.*, set.value, writer);
                    },
                    .Mut => |m| {
                        try serde.serialize(m.idx, writer);
                        try writeFieldTypeMut(child_info.*, m.mut, writer);
                    },
                }
            }
        },
        .Map => |map_info| {
            try serde.serialize(mut.inner.items.len, writer);
            for (mut.inner.items) |item| {
                try serde.serialize(@intFromEnum(item), writer);
                switch (item) {
                    .Put, .PutNoClobber => |kv| {
                        try writeFieldTypeValue(map_info.key.*, kv.key, writer);
                        try writeFieldTypeValue(map_info.value.*, kv.value, writer);
                    },
                    .Remove => |key| {
                        try writeFieldTypeValue(map_info.key.*, key, writer);
                    },
                    .Swap => |swap| {
                        try writeFieldTypeValue(map_info.key.*, swap.old, writer);
                        try writeFieldTypeValue(map_info.key.*, swap.new, writer);
                    },
                    .MutKey => |mk| {
                        try writeFieldTypeValue(map_info.key.*, mk.key, writer);
                        try writeFieldTypeMut(map_info.key.*, mk.mut, writer);
                    },
                    .MutValue => |mv| {
                        try writeFieldTypeValue(map_info.key.*, mv.key, writer);
                        try writeFieldTypeMut(map_info.value.*, mv.value, writer);
                    },
                }
            }
        },
        .Struct => |fields| {
            inline for (fields) |field| {
                if (@field(mut, field.name)) |fm| {
                    try writer.writeByte(1);
                    try writeFieldTypeMut(field.type, fm, writer);
                } else {
                    try writer.writeByte(0);
                }
            }
        },
        .Tuple => |fields| {
            inline for (fields, 0..) |field, i| {
                if (mut[i]) |fm| {
                    try writer.writeByte(1);
                    try writeFieldTypeMut(field, fm, writer);
                } else {
                    try writer.writeByte(0);
                }
            }
        },
        .Union => |fields| {
            switch (mut) {
                inline else => |val, tag| {
                    const field = fields[@intFromEnum(tag)];
                    try writeFieldTypeMut(field.type, val, writer);
                },
            }
        },
    }
}

const define = @import("../define.zig");
const TestScheme = define.Scheme("test", .{
    define.Object("TestObj", .{
        struct {
            boolean: bool,
            int: u16,
            float: f16,
            ref: define.This("TestObj"),
            str: define.String,
            enum_: enum {
                Tag1,
                Tag2,
            },
            opt: ?bool,
            array: define.Array(2, bool),
            list: define.List(bool),
            map: define.Map(u8, bool),
            tuple: struct { u8, u16 },
            union_: union(enum) {
                Tag1: u8,
                Tag2: u16,
            },
        },
    }),
});
const TestObj = TestScheme("TestObj");
test "ObjectValue" {
    const ObjValue = ObjectValue(TestObj);

    var obj = ObjValue{ .v1 = undefined };
    var value = @TypeOf(obj.v1){
        .boolean = true,
        .int = 10,
        .float = 100.0,
        .ref = super.ObjectId{ .scheme = 0, .source = 0, .name = 0 },
        .str = "value",
        .enum_ = .Tag1,
        .opt = null,
        .array = [_]bool{ true, false },
        .list = undefined,
        .map = undefined,
        .tuple = .{ 10, 20 },
        .union_ = .{
            .Tag2 = 100,
        },
    };
    value.list = @TypeOf(value.list).init(std.testing.allocator);
    defer value.list.deinit();
    try value.list.append(true);

    value.map = @TypeOf(value.map).init(std.testing.allocator);
    defer value.map.deinit();
    try value.map.append(.{ .key = 10, .value = false });

    obj.v1 = value;

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try writeValue(TestObj, obj, buf.writer());
}

test "ObjectMut" {
    const ObjMut = ObjectMut(TestObj);

    var obj = ObjMut{ .v1 = undefined };
    var mut = @TypeOf(obj.v1){
        .boolean = null,
        .int = null,
        .float = null,
        .ref = null,
        .str = null,
        .enum_ = null,
        .opt = null,
        .array = null,
        .list = null,
        .map = null,
        .tuple = null,
        .union_ = null,
    };
    obj.v1 = mut;

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try writeMut(TestObj, obj, buf.writer());
}
