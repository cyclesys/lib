const std = @import("std");
const define = @import("define.zig");

pub const Type = union(enum) {
    Void: void,
    Bool: void,
    String: void,
    Int: Int,
    Float: Float,
    Optional: Optional,
    Array: Array,
    List: List,
    Map: Map,
    Struct: Struct,
    Tuple: Tuple,
    Union: Union,
    Enum: Enum,
    Ref: Ref,
    Any: void,

    pub const Int = struct {
        signedness: Signedness,
        bits: u16,

        pub const Signedness = enum {
            signed,
            unsigned,
        };
    };

    pub const Float = struct {
        bits: u16,
    };

    pub const Optional = struct {
        child: *const Type,
    };

    pub const Array = struct {
        len: u64,
        child: *const Type,
    };

    pub const List = struct {
        child: *const Type,
    };

    pub const Map = struct {
        key: *const Type,
        value: *const Type,
    };

    pub const Struct = struct {
        fields: []const Field,

        pub const Field = struct {
            name: []const u8,
            type: Type,
        };
    };

    pub const Tuple = struct {
        fields: []const Field,

        pub const Field = struct {
            type: Type,
        };
    };

    pub const Union = struct {
        fields: []const Field,

        pub const Field = struct {
            name: []const u8,
            type: Type,
        };
    };

    pub const Enum = struct {
        fields: []const Field,

        pub const Field = struct {
            name: []const u8,
        };
    };

    pub const Ref = union(enum) {
        Internal: Internal,
        External: External,

        pub const Internal = struct {
            name: []const u8,
        };

        pub const External = struct {
            scheme: []const u8,
            name: []const u8,
        };

        fn eql(left: Ref, right: Ref) bool {
            if (left.scheme != null) {
                if (right.scheme == null or !std.mem.eql(u8, left.scheme.?, right.scheme.?)) {
                    return false;
                }
            } else if (right.scheme != null) {
                return false;
            }

            return std.mem.eql(u8, left.name, right.name);
        }
    };

    pub fn from(comptime T: type) ?Type {
        return switch (@typeInfo(T)) {
            .Void => .Void,
            .Bool => .Bool,
            .Int => |info| Type{
                .Int = Int{
                    .signedness = switch (info.signedness) {
                        .signed => .signed,
                        .unsigned => .unsigned,
                    },
                    .bits = info.bits,
                },
            },
            .Float => |info| Type{
                .Float = Float{
                    .bits = info.bits,
                },
            },
            .Optional => |info| comptime blk: {
                const child = Type.from(info.child).?;
                break :blk Type{
                    .Optional = Optional{
                        .child = &child,
                    },
                };
            },
            .Array => |info| comptime blk: {
                const child = Type.from(info.child).?;
                break :blk Type{
                    .Array = Array{
                        .len = info.len,
                        .child = &child,
                    },
                };
            },
            .Struct => |info| if (@hasDecl(T, "def_kind")) switch (T.def_kind) {
                .ref => Type{
                    .Ref = Ref{
                        .External = Ref.External{
                            .scheme = T.scheme.name,
                            .name = T.def.name,
                        },
                    },
                },
                .this => Type{
                    .Ref = Ref{
                        .Internal = Ref.Internal{
                            .name = T.name,
                        },
                    },
                },
                .list => comptime blk: {
                    const child = Type.from(T.child).?;
                    break :blk Type{
                        .List = List{
                            .child = &child,
                        },
                    };
                },
                .map => comptime blk: {
                    const key = Type.from(T.key).?;
                    const value = Type.from(T.value).?;
                    break :blk Type{
                        .Map = Map{
                            .key = &key,
                            .value = &value,
                        },
                    };
                },
                .string => .String,
                .any => .Any,
                .ignore => null,
                else => @compileError("unexpected def_kind"),
            } else if (info.is_tuple) comptime blk: {
                var fields: [info.fields.len]Tuple.Field = undefined;
                var len = 0;
                for (info.fields) |field| {
                    if (Type.from(field.type)) |field_type| {
                        fields[len] = Tuple.Field{
                            .type = field_type,
                        };
                        len += 1;
                    }
                }
                break :blk Type{
                    .Tuple = Tuple{
                        .fields = fields[0..len],
                    },
                };
            } else comptime blk: {
                var fields: [info.fields.len]Struct.Field = undefined;
                var len = 0;
                for (info.fields) |field| {
                    if (Type.from(field.type)) |field_type| {
                        fields[len] = Struct.Field{
                            .name = field.name,
                            .type = field_type,
                        };
                        len += 1;
                    }
                }
                break :blk Type{
                    .Struct = Struct{
                        .fields = fields[0..len],
                    },
                };
            },
            .Union => |info| comptime blk: {
                if (info.tag_type == null) {
                    @compileError("union field type must have tag type");
                }

                var fields: [info.fields.len]Union.Field = undefined;
                var len = 0;
                for (info.fields) |field| {
                    if (Type.from(field.type)) |field_type| {
                        fields[len] = Union.Field{
                            .name = field.name,
                            .type = field_type,
                        };
                        len += 1;
                    }
                }
                break :blk Type{
                    .Union = Union{
                        .fields = fields[0..len],
                    },
                };
            },
            .Enum => |info| comptime blk: {
                var fields: [info.fields.len]Enum.Field = undefined;
                for (info.fields, 0..) |field, i| {
                    fields[i] = Enum.Field{
                        .name = field.name,
                    };
                }
                break :blk Type{
                    .Enum = Enum{
                        .fields = &fields,
                    },
                };
            },
            else => @compileError("unexpected field type"),
        };
    }

    pub fn eql(l: ?Type, r: ?Type) bool {
        if (l == null) {
            return r == null;
        } else if (r == null) {
            return false;
        }

        const left = l.?;
        const right = r.?;

        return switch (left) {
            .Void => right == .Void,
            .Bool => right == .Bool,
            .String => right == .String,

            .Int => right == .Int and
                left.Int.signedness == right.Int.signedness and
                left.Int.bits == right.Int.bits,

            .Float => right == .Float and
                left.Float.bits == right.Float.bits,

            .Optional => right == .Optional and
                Type.eql(left.Optional.child.*, right.Optional.child.*),

            .Array => right == .Array and
                left.Array.len == right.Array.len and
                Type.eql(left.Array.child.*, right.Array.child.*),

            .List => right == .List and
                Type.eql(left.List.child.*, right.List.child.*),

            .Map => right == .Map and
                Type.eql(left.Map.key.*, right.Map.key.*) and
                Type.eql(left.Map.value.*, right.Map.value.*),

            .Struct => if (right != .Struct or left.Struct.fields.len != right.Struct.fields.len)
                false
            else for (left.Struct.fields, right.Struct.fields) |left_field, right_field| {
                if (!std.mem.eql(u8, left_field.name, right_field.name) or
                    !Type.eql(left_field.type, right_field.type))
                {
                    break false;
                }
            } else true,

            .Tuple => if (right != .Tuple or left.Tuple.fields.len != right.Tuple.fields.len)
                false
            else for (left.Tuple.fields, right.Tuple.fields) |left_field, right_field| {
                if (!Type.eql(left_field.type, right_field.type)) {
                    break false;
                }
            } else true,

            .Union => if (right != .Union or left.Union.fields.len != right.Union.fields.len)
                false
            else for (left.Union.fields, right.Union.fields) |left_field, right_field| {
                if (!std.mem.eql(u8, left_field.name, right_field.name) or
                    !Type.eql(left_field.type, right_field.type))
                {
                    break false;
                }
            } else true,

            .Enum => if (right != .Enum or left.Enum.fields.len != right.Enum.fields.len)
                false
            else for (left.Enum.fields, right.Enum.fields) |left_field, right_field| {
                if (!std.mem.eql(u8, left_field.name, right_field.name)) {
                    break false;
                }
            } else true,

            .Ref => right == .Ref and switch (left.Ref) {
                .Internal => right.Ref == .Internal and
                    std.mem.eql(u8, left.Ref.Internal.name, right.Ref.Internal.name),
                .External => right.Ref == .External and
                    std.mem.eql(u8, left.Ref.External.scheme, right.Ref.External.scheme) and
                    std.mem.eql(u8, left.Ref.External.name, right.Ref.External.name),
            },

            .Any => right == .Any,
        };
    }
};

test "void type" {
    try expectTypeEql(.Void, Type.from(void));
}

test "bool type" {
    try expectTypeEql(.Bool, Type.from(bool));
}

test "int type" {
    try expectTypeEql(
        .{
            .Int = .{
                .signedness = .signed,
                .bits = 8,
            },
        },
        Type.from(i8),
    );
    try expectTypeEql(
        .{
            .Int = .{
                .signedness = .unsigned,
                .bits = 8,
            },
        },
        Type.from(u8),
    );
}

test "float type" {
    try expectTypeEql(Type{ .Float = .{ .bits = 16 } }, Type.from(f16));
}

test "optional type" {
    try expectTypeEql(
        .{
            .Optional = .{
                .child = &.{
                    .Int = .{
                        .signedness = .unsigned,
                        .bits = 8,
                    },
                },
            },
        },
        Type.from(?u8),
    );
}

test "ref type" {
    const Objs = define.Scheme("objs", .{
        define.Object("Obj", .{
            u8,
        }),
    });
    try expectTypeEql(
        .{
            .Ref = .{
                .External = .{
                    .scheme = "objs",
                    .name = "Obj",
                },
            },
        },
        Type.from(Objs.ref("Obj")),
    );
}

test "array type" {
    try expectTypeEql(
        .{
            .Array = .{
                .len = 32,
                .child = &.{
                    .Bool = undefined,
                },
            },
        },
        Type.from([32]bool),
    );
}

test "list type" {
    try expectTypeEql(
        .{
            .List = .{
                .child = &.{
                    .Bool = undefined,
                },
            },
        },
        Type.from(define.List(bool)),
    );
}

test "map type" {
    try expectTypeEql(
        .{
            .Map = .{
                .key = &.{ .Bool = undefined },
                .value = &.{ .Bool = undefined },
            },
        },
        Type.from(define.Map(bool, bool)),
    );
}

test "string type" {
    try expectTypeEql(
        .{
            .String = undefined,
        },
        Type.from(define.String),
    );
}

test "any type" {
    try expectTypeEql(
        .{
            .Any = undefined,
        },
        Type.from(define.Any),
    );
}

test "struct type" {
    const expected = .{
        Type.Struct.Field{
            .name = "one",
            .type = Type.Bool,
        },
        Type.Struct.Field{
            .name = "two",
            .type = Type.String,
        },
    };
    try expectTypeEql(
        .{
            .Struct = .{
                .fields = &expected,
            },
        },
        Type.from(struct {
            one: bool,
            two: define.String,
        }),
    );
}

test "tuple type" {
    const expected = .{
        Type.Tuple.Field{
            .type = Type.Bool,
        },
        Type.Tuple.Field{
            .type = Type.String,
        },
    };
    try expectTypeEql(
        .{
            .Tuple = .{
                .fields = &expected,
            },
        },
        Type.from(struct {
            bool,
            define.String,
        }),
    );
}

test "union type" {
    const expected_fields = .{
        Type.Union.Field{
            .name = "One",
            .type = Type.Bool,
        },
        Type.Union.Field{
            .name = "Two",
            .type = Type.String,
        },
    };
    try expectTypeEql(
        .{
            .Union = .{
                .fields = &expected_fields,
            },
        },
        Type.from(union(enum) {
            One: bool,
            Two: define.String,
        }),
    );
}

test "enum type" {
    try expectTypeEql(
        .{
            .Enum = .{
                .fields = &.{
                    .{
                        .name = "One",
                    },
                    .{
                        .name = "Two",
                    },
                },
            },
        },
        Type.from(enum {
            One,
            Two,
        }),
    );
}

fn expectTypeEql(expected: ?Type, actual: ?Type) !void {
    // uses the `FieldType.eql` implementation since it does everything, including chasing pointers.
    if (!Type.eql(expected, actual)) {
        return error.TestExpectedEqual;
    }
}
