const std = @import("std");
const define = @import("define.zig");

pub const CommandScheme = struct {
    name: []const u8,
    commands: []const Command,
    dependencies: []const ObjectScheme,

    pub const Command = struct {
        name: []const u8,
        type: Type,

        fn from(comptime T: type) Command {
            return comptime blk: {
                const t = Type.from(T.cmd_type);
                checkCommandType(t);
                break :blk Command{
                    .name = T.name,
                    .type = t.?,
                };
            };
        }

        fn checkCommandType(comptime t: ?Type) void {
            if (t == null) {
                @compileError("command type cannot be Ignore");
            }

            switch (t.?) {
                .Array => |info| checkCommandType(info.child.*),
                .List => |info| checkCommandType(info.child.*),
                .Struct => |info| for (info.fields) |f| {
                    checkCommandType(f.type);
                },
                .Union => |info| for (info.fields) |f| {
                    if (f.type == .Void) continue;
                    checkCommandType(f.type);
                },
                .Ref => {},
                else => @compileError("command type must be Array, List, Struct, Union, or Ref type"),
            }
        }
    };

    pub fn from(comptime SchemeFn: define.SchemeFn) CommandScheme {
        const Scheme = SchemeFn(define.This);
        if (Scheme.kind != .command) {
            @compileError("scheme is not a command scheme");
        }

        const result = comptime blk: {
            var commands: [Scheme.types.len]Command = undefined;
            for (Scheme.types, 0..) |T, i| {
                commands[i] = Command.from(T);
            }

            var dependency_types: []const type = &[_]type{};
            for (Scheme.types) |T| {
                var deps: []const type = &[_]type{};
                for (ObjectScheme.types(T.cmd_type)) |Dep| {
                    deps = ObjectScheme.mergeTypes(deps, &[_]type{Dep});
                    deps = ObjectScheme.mergeTypes(deps, ObjectScheme.dependencies(Dep));
                }
                dependency_types = ObjectScheme.mergeTypes(dependency_types, deps);
            }

            var dependencies: [dependency_types.len]ObjectScheme = undefined;
            for (dependency_types, 0..) |Dep, i| {
                dependencies[i] = ObjectScheme.from(Dep);
            }

            break :blk CommandScheme{
                .name = Scheme.name,
                .commands = commands[0..],
                .dependencies = ObjectScheme.mergeSchemes(dependencies[0..]),
            };
        };

        return result;
    }
};

pub const FunctionScheme = struct {
    name: []const u8,
    functions: []const Function,
    dependencies: []const ObjectScheme,

    pub const Function = struct {
        name: []const u8,
        versions: []const Version,

        pub const Version = struct {
            params: []const Type,
            return_type: Type,

            fn from(comptime T: type) Version {
                const info = @typeInfo(T).Fn;

                const result = comptime blk: {
                    var params: [info.params.len]Type = undefined;
                    for (info.params, 0..) |param, i| {
                        params[i] = Type.from(param.type.?).?;
                    }

                    const return_type = Type.from(info.return_type.?).?;

                    break :blk Version{
                        .params = params[0..],
                        .return_type = return_type,
                    };
                };

                return result;
            }
        };

        fn from(comptime T: type) Function {
            const result = comptime blk: {
                var versions: [T.versions.len]Version = undefined;
                for (T.versions, 0..) |Ver, i| {
                    versions[i] = Version.from(Ver);
                }
                break :blk Function{
                    .name = T.name,
                    .versions = versions[0..],
                };
            };
            return result;
        }
    };

    pub fn from(comptime SchemeFn: define.SchemeFn) FunctionScheme {
        const Scheme = SchemeFn(define.This);
        if (Scheme.kind != .function) {
            @compileError("scheme is not a function scheme");
        }

        const result = comptime blk: {
            var functions: [Scheme.types.len]Function = undefined;
            for (Scheme.types, 0..) |T, i| {
                functions[i] = Function.from(T);
            }

            var dependency_types: []const type = &[_]type{};
            for (Scheme.types) |T| {
                for (T.versions) |Ver| {
                    var deps: []const type = &[_]type{};
                    for (ObjectScheme.types(Ver)) |Dep| {
                        deps = ObjectScheme.mergeTypes(deps, &[_]type{Dep});
                        deps = ObjectScheme.mergeTypes(deps, ObjectScheme.dependencies(Dep));
                    }
                    dependency_types = ObjectScheme.mergeTypes(dependency_types, deps);
                }
            }

            var dependencies: [dependency_types.len]ObjectScheme = undefined;
            for (dependency_types, 0..) |Dep, i| {
                dependencies[i] = ObjectScheme.from(Dep);
            }

            break :blk FunctionScheme{
                .name = Scheme.name,
                .functions = functions[0..],
                .dependencies = ObjectScheme.mergeSchemes(dependencies[0..]),
            };
        };

        return result;
    }
};

pub const ObjectScheme = struct {
    name: []const u8,
    objects: []const Object,

    pub const Object = struct {
        name: []const u8,
        versions: []const Type,

        fn merge(comptime left: Object, comptime right: Object) Object {
            if (left.versions.len > right.versions.len) {
                return left;
            } else if (right.versions.len > left.versions.len) {
                return right;
            } else {
                @compileError("unexpected Object.merge state");
            }
        }

        fn eql(comptime left: Object, comptime right: Object) bool {
            const matching_len = if (left.versions.len > right.versions.len)
                right.versions.len
            else
                left.versions.len;

            for (0..matching_len) |i| {
                if (!Type.eql(left.versions[i], right.versions[i])) {
                    @compileError("encountered differing field types for object " ++ left.name ++
                        "at version " ++ &[_]u8{i});
                }
            }

            return left.versions.len == right.versions.len;
        }

        fn from(comptime T: type) Object {
            const result = comptime blk: {
                var versions: [T.versions.len]Type = undefined;
                for (T.versions, 0..) |Ver, i| {
                    versions[i] = Type.from(Ver).?;
                }
                break :blk Object{
                    .name = T.name,
                    .versions = versions[0..],
                };
            };
            return result;
        }
    };

    fn types(comptime T: type) []const type {
        comptime {
            switch (@typeInfo(T)) {
                .Void, .Bool, .Int, .Float, .Enum => {
                    return &[_]type{};
                },
                .Optional => |info| {
                    return ObjectScheme.types(info.child);
                },
                .Struct => |info| {
                    if (@hasDecl(T, "def_kind")) {
                        switch (T.def_kind) {
                            .this, .string, .ignore => {
                                return &[_]type{};
                            },
                            .ref => {
                                return &[_]type{T.scheme};
                            },
                            .array, .list => {
                                return ObjectScheme.types(T.child);
                            },
                            .map => {
                                return ObjectScheme.mergeTypes(
                                    ObjectScheme.types(T.key),
                                    ObjectScheme.types(T.value),
                                );
                            },
                            else => @compileError("unexpected field type"),
                        }
                    } else {
                        var result: []const type = &[_]type{};
                        for (info.fields) |field| {
                            result = ObjectScheme.mergeTypes(result, ObjectScheme.types(field.type));
                        }
                        return result;
                    }
                },
                .Union => |info| {
                    var result: []const type = &[_]type{};
                    for (info.fields) |field| {
                        result = ObjectScheme.mergeTypes(result, ObjectScheme.types(field.type));
                    }
                    return result;
                },
                .Fn => |info| {
                    var result: []const type = &[_]type{};
                    for (info.params) |param| {
                        result = ObjectScheme.mergeTypes(result, ObjectScheme.types(param.type.?));
                    }
                    result = ObjectScheme.mergeTypes(result, ObjectScheme.types(info.return_type.?));
                    return result;
                },
                else => @compileError("unexpected field type"),
            }
        }
    }

    pub fn dependencies(comptime Scheme: type) []const type {
        comptime {
            var result: []const type = &[_]type{};
            for (Scheme.types) |T| {
                for (T.versions) |Ver| {
                    var deps: []const type = &[_]type{};
                    for (ObjectScheme.types(Ver)) |Dep| {
                        if (Dep == Scheme)
                            continue;

                        deps = ObjectScheme.mergeTypes(deps, &[_]type{Dep});
                        deps = ObjectScheme.mergeTypes(deps, ObjectScheme.dependencies(Dep));
                    }
                    result = ObjectScheme.mergeTypes(result, deps);
                }
            }
            return result;
        }
    }

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

    pub fn mergeSchemes(comptime deps: []const ObjectScheme) []const ObjectScheme {
        const result = comptime blk: {
            var schemes: [deps.len]ObjectScheme = undefined;
            var len = 0;
            outer: for (deps) |new| {
                for (0..len) |i| {
                    if (std.mem.eql(u8, schemes[i].name, new.name)) {
                        schemes[i] = ObjectScheme.merge(schemes[i], new);
                        continue :outer;
                    }
                }

                schemes[len] = new;
                len += 1;
            }
            break :blk schemes[0..len];
        };
        return result;
    }

    fn merge(comptime left: ObjectScheme, comptime right: ObjectScheme) ObjectScheme {
        const result = comptime blk: {
            var objects: [left.objects.len + right.objects.len]Object = undefined;
            for (left.objects, 0..) |obj, i| {
                objects[i] = obj;
            }
            var len = left.objects.len;

            outer: for (right.objects) |right_obj| {
                for (left.objects, 0..) |left_obj, i| {
                    if (std.mem.eql(u8, left_obj.name, right_obj.name)) {
                        if (!Object.eql(left_obj, right_obj)) {
                            objects[i] = Object.merge(left_obj, right_obj);
                        }
                        continue :outer;
                    }
                }
                objects[len] = right_obj;
                len += 1;
            }
            break :blk ObjectScheme{
                .name = left.name,
                .objects = objects[0..len],
            };
        };
        return result;
    }

    pub fn from(comptime Scheme: type) ObjectScheme {
        if (Scheme.kind != .object) {
            @compileError("scheme is not an object scheme");
        }

        const result = comptime blk: {
            var objects: [Scheme.types.len]Object = undefined;
            for (Scheme.types, 0..) |T, i| {
                objects[i] = Object.from(T);
            }
            break :blk ObjectScheme{
                .name = Scheme.name,
                .objects = objects[0..],
            };
        };

        return result;
    }
};

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
        len: usize,
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
        fields: []const Type,
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
            .Struct => |info| if (@hasDecl(T, "def_kind")) switch (T.def_kind) {
                .this => Type{
                    .Ref = Ref{
                        .Internal = Ref.Internal{
                            .name = T.name,
                        },
                    },
                },
                .ref => Type{
                    .Ref = Ref{
                        .External = Ref.External{
                            .scheme = T.scheme.name,
                            .name = T.def.name,
                        },
                    },
                },
                .array => comptime blk: {
                    const child = Type.from(T.child).?;
                    break :blk Type{
                        .Array = Array{
                            .len = T.len,
                            .child = &child,
                        },
                    };
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
                .ignore => null,
                else => @compileError("unexpected def_kind"),
            } else if (info.is_tuple) comptime blk: {
                var field_types: [info.fields.len]Type = undefined;
                var len = 0;
                for (info.fields) |field| {
                    if (Type.from(field.type)) |field_type| {
                        field_types[len] = field_type;
                        len += 1;
                    }
                }
                break :blk Type{
                    .Tuple = Tuple{
                        .fields = field_types[0..len],
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

    fn eql(l: ?Type, r: ?Type) bool {
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
            else for (left.Tuple.fields, right.Tuple.fields) |left_type, right_type| {
                if (!Type.eql(left_type, right_type)) {
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
        };
    }
};

// NOTE: the tests don't use `testing.expectEqualDeep` due to `FieldType` being a recursive type,
// which causes a compilation error when zig tries to infer the error type. Instead they use
// hand-writter 'expect' functions, defined at the very bottom.

test "void field type" {
    try expectTypeEql(.Void, Type.from(void));
}

test "bool field type" {
    try expectTypeEql(.Bool, Type.from(bool));
}

test "int field type" {
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

test "float field type" {
    try expectTypeEql(Type{ .Float = .{ .bits = 16 } }, Type.from(f16));
}

test "optional field type" {
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

test "ref field type" {
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
        Type.from(Objs("Obj")),
    );
}

test "array field type" {
    try expectTypeEql(
        .{
            .Array = .{
                .len = 32,
                .child = &.{
                    .Bool = undefined,
                },
            },
        },
        Type.from(define.Array(32, bool)),
    );
}

test "list field type" {
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

test "map field type" {
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

test "string field type" {
    try expectTypeEql(
        .{
            .String = undefined,
        },
        Type.from(define.String),
    );
}

test "struct field type" {
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

test "tuple field type" {
    const expected = .{
        Type.Bool,
        Type.String,
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

test "union field type" {
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

test "enum field type" {
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

test "object" {
    const Obj = define.Object("Obj", .{
        bool,
        define.String,
    });

    try expectObjectEql(
        .{
            .name = "Obj",
            .versions = &.{
                .Bool,
                .String,
            },
        },
        ObjectScheme.Object.from(Obj),
    );
}

test "object scheme" {
    const Objs = define.Scheme("scheme/objs", .{
        define.Object("One", .{
            bool,
        }),
    });

    try expectObjectSchemeEql(
        .{
            .name = "scheme/objs",
            .objects = &.{
                .{
                    .name = "One",
                    .versions = &.{
                        .Bool,
                    },
                },
            },
        },
        ObjectScheme.from(Objs(define.This)),
    );
}

test "object scheme dependencies" {
    const Dep1 = define.Scheme("scheme/dep1", .{
        define.Object("Obj", .{
            bool,
        }),
    });

    const Dep2 = define.Scheme("scheme/dep2", .{
        define.Object("Obj", .{
            struct {
                obj1: Dep1("Obj"),
            },
        }),
    });

    const Objs = define.Scheme("scheme/objs", .{
        define.Object("One", .{
            struct {
                obj1: Dep1("Obj"),
                obj2: Dep2("Obj"),
            },
        }),
    });

    const expected: []const ObjectScheme = &.{
        .{
            .name = "scheme/dep1",
            .objects = &.{
                .{
                    .name = "Obj",
                    .versions = &.{
                        .Bool,
                    },
                },
            },
        },
        .{
            .name = "scheme/dep2",
            .objects = &.{
                .{
                    .name = "Obj",
                    .versions = &.{
                        .{
                            .Struct = .{
                                .fields = &.{
                                    .{
                                        .name = "obj1",
                                        .type = .{
                                            .Ref = .{
                                                .External = .{
                                                    .scheme = "scheme/dep1",
                                                    .name = "Obj",
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    };

    const deps = ObjectScheme.dependencies(Objs(define.This));
    inline for (deps, 0..) |dep, i| {
        const actual = ObjectScheme.from(dep);
        try expectObjectSchemeEql(expected[i], actual);
    }
}

test "object scheme merge" {
    const DepOld = define.Scheme("scheme/dep", .{
        define.Object("One", .{
            bool,
        }),
    });

    const DepNew = define.Scheme("scheme/dep", .{
        define.Object("One", .{
            bool,
            define.String,
        }),
        define.Object("Two", .{
            define.String,
        }),
    });

    const Dep2 = define.Scheme("scheme/dep2", .{
        define.Object("Obj", .{
            DepOld("One"),
        }),
    });

    const Objs = define.Scheme("scheme/objs", .{
        define.Object("Obj", .{
            struct {
                one: DepNew("One"),
                two: DepNew("Two"),
                obj: Dep2("Obj"),
            },
        }),
    });

    const expected: []const ObjectScheme = &.{
        .{
            .name = "scheme/dep",
            .objects = &.{
                .{
                    .name = "One",
                    .versions = &.{
                        .Bool,
                        .String,
                    },
                },
                .{
                    .name = "Two",
                    .versions = &.{
                        .String,
                    },
                },
            },
        },
        .{
            .name = "scheme/dep2",
            .objects = &.{
                .{
                    .name = "Obj",
                    .versions = &.{
                        .{
                            .Ref = .{
                                .External = .{
                                    .scheme = "scheme/dep",
                                    .name = "One",
                                },
                            },
                        },
                    },
                },
            },
        },
    };

    const actual = comptime blk: {
        var schemes: []const ObjectScheme = &[_]ObjectScheme{};
        for (ObjectScheme.dependencies(Objs(define.This))) |dep| {
            schemes = schemes ++ &[_]ObjectScheme{ObjectScheme.from(dep)};
        }
        break :blk ObjectScheme.mergeSchemes(schemes);
    };

    inline for (expected, actual) |exp, act| {
        try expectObjectSchemeEql(exp, act);
    }
}

test "function version" {
    try expectFunctionVersionEql(
        .{
            .params = &.{
                .Bool,
            },
            .return_type = .Bool,
        },
        FunctionScheme.Function.Version.from(fn (bool) bool),
    );
}

test "function" {
    const Fn = define.Function("Fn", .{
        fn (bool) define.String,
    });

    try expectFunctionEql(
        .{
            .name = "Fn",
            .versions = &.{
                .{
                    .params = &.{
                        .Bool,
                    },
                    .return_type = .String,
                },
            },
        },
        FunctionScheme.Function.from(Fn),
    );
}

test "function scheme" {
    const Dep1Old = define.Scheme("dep1", .{
        define.Object("Obj", .{
            bool,
        }),
    });

    const Dep1New = define.Scheme("dep1", .{
        define.Object("Obj", .{
            bool,
            define.String,
        }),
    });

    const Dep2 = define.Scheme("dep2", .{
        define.Object("Obj", .{
            Dep1Old("Obj"),
        }),
    });

    const Dep3 = define.Scheme("dep3", .{
        define.Object("Obj", .{
            struct {
                obj1: Dep1New("Obj"),
                obj2: Dep2("Obj"),
            },
        }),
    });

    const Fns = define.Scheme("Fns", .{
        define.Function("Fn", .{
            fn (Dep2("Obj")) Dep3("Obj"),
        }),
    });

    try expectFunctionSchemeEql(
        .{
            .name = "Fns",
            .functions = &.{
                .{
                    .name = "Fn",
                    .versions = &.{
                        .{
                            .params = &.{
                                .{
                                    .Ref = .{
                                        .External = .{
                                            .scheme = "dep2",
                                            .name = "Obj",
                                        },
                                    },
                                },
                            },
                            .return_type = .{
                                .Ref = .{
                                    .External = .{
                                        .scheme = "dep3",
                                        .name = "Obj",
                                    },
                                },
                            },
                        },
                    },
                },
            },
            .dependencies = &.{
                .{
                    .name = "dep2",
                    .objects = &.{
                        .{
                            .name = "Obj",
                            .versions = &.{
                                .{
                                    .Ref = .{
                                        .External = .{
                                            .scheme = "dep1",
                                            .name = "Obj",
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
                .{
                    .name = "dep1",
                    .objects = &.{
                        .{
                            .name = "Obj",
                            .versions = &.{
                                .Bool,
                                .String,
                            },
                        },
                    },
                },
                .{
                    .name = "dep3",
                    .objects = &.{
                        .{
                            .name = "Obj",
                            .versions = &.{
                                .{
                                    .Struct = .{
                                        .fields = &.{
                                            .{
                                                .name = "obj1",
                                                .type = .{
                                                    .Ref = .{
                                                        .External = .{
                                                            .scheme = "dep1",
                                                            .name = "Obj",
                                                        },
                                                    },
                                                },
                                            },
                                            .{
                                                .name = "obj2",
                                                .type = .{
                                                    .Ref = .{
                                                        .External = .{
                                                            .scheme = "dep2",
                                                            .name = "Obj",
                                                        },
                                                    },
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
        FunctionScheme.from(Fns),
    );
}

test "command" {
    const Objs = define.Scheme("objs", .{
        define.Object("Obj", .{
            bool,
        }),
    });
    const Cmd = define.Command("Cmd", struct {
        obj: Objs("Obj"),
    });

    try expectCommandEql(
        .{
            .name = "Cmd",
            .type = .{
                .Struct = .{
                    .fields = &.{
                        .{
                            .name = "obj",
                            .type = .{
                                .Ref = .{
                                    .External = .{
                                        .scheme = "objs",
                                        .name = "Obj",
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
        CommandScheme.Command.from(Cmd),
    );
}

test "command scheme" {
    const Dep1Old = define.Scheme("dep1", .{
        define.Object("Obj", .{
            bool,
        }),
    });

    const Dep1New = define.Scheme("dep1", .{
        define.Object("Obj", .{
            bool,
            define.String,
        }),
    });

    const Dep2 = define.Scheme("dep2", .{
        define.Object("Obj", .{
            Dep1Old("Obj"),
        }),
    });

    const Dep3 = define.Scheme("dep3", .{
        define.Object("Obj", .{
            struct {
                obj1: Dep1New("Obj"),
                obj2: Dep2("Obj"),
            },
        }),
    });

    const Cmds = define.Scheme("cmds", .{
        define.Command("Cmd", struct {
            obj2: Dep2("Obj"),
            obj3: Dep3("Obj"),
        }),
    });

    try expectCommandSchemeEql(
        .{
            .name = "cmds",
            .commands = &.{
                .{
                    .name = "Cmd",
                    .type = .{
                        .Struct = .{
                            .fields = &.{
                                .{
                                    .name = "obj2",
                                    .type = .{
                                        .Ref = .{
                                            .External = .{
                                                .scheme = "dep2",
                                                .name = "Obj",
                                            },
                                        },
                                    },
                                },
                                .{
                                    .name = "obj3",
                                    .type = .{
                                        .Ref = .{
                                            .External = .{
                                                .scheme = "dep3",
                                                .name = "Obj",
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
            .dependencies = &.{
                .{
                    .name = "dep2",
                    .objects = &.{
                        .{
                            .name = "Obj",
                            .versions = &.{
                                .{
                                    .Ref = .{
                                        .External = .{
                                            .scheme = "dep1",
                                            .name = "Obj",
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
                .{
                    .name = "dep1",
                    .objects = &.{
                        .{
                            .name = "Obj",
                            .versions = &.{
                                .Bool,
                                .String,
                            },
                        },
                    },
                },
                .{
                    .name = "dep3",
                    .objects = &.{
                        .{
                            .name = "Obj",
                            .versions = &.{
                                .{
                                    .Struct = .{
                                        .fields = &.{
                                            .{
                                                .name = "obj1",
                                                .type = .{
                                                    .Ref = .{
                                                        .External = .{
                                                            .scheme = "dep1",
                                                            .name = "Obj",
                                                        },
                                                    },
                                                },
                                            },
                                            .{
                                                .name = "obj2",
                                                .type = .{
                                                    .Ref = .{
                                                        .External = .{
                                                            .scheme = "dep2",
                                                            .name = "Obj",
                                                        },
                                                    },
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
        CommandScheme.from(Cmds),
    );
}

fn expectCommandSchemeEql(expected: CommandScheme, actual: CommandScheme) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or
        expected.commands.len != actual.commands.len or
        expected.dependencies.len != actual.dependencies.len)
    {
        return error.TestExpectedEqual;
    }

    for (expected.commands, actual.commands) |exp, act| {
        try expectCommandEql(exp, act);
    }

    for (expected.dependencies, actual.dependencies) |exp, act| {
        try expectObjectSchemeEql(exp, act);
    }
}

fn expectCommandEql(expected: CommandScheme.Command, actual: CommandScheme.Command) !void {
    if (!std.mem.eql(u8, expected.name, actual.name)) {
        return error.TestExpectedEqual;
    }

    try expectTypeEql(expected.type, actual.type);
}

fn expectFunctionSchemeEql(expected: FunctionScheme, actual: FunctionScheme) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or
        expected.functions.len != actual.functions.len or
        expected.dependencies.len != actual.dependencies.len)
    {
        return error.TestExpectedEqual;
    }

    for (expected.functions, actual.functions) |exp, act| {
        try expectFunctionEql(exp, act);
    }

    for (expected.dependencies, actual.dependencies) |exp, act| {
        try expectObjectSchemeEql(exp, act);
    }
}

fn expectFunctionEql(expected: FunctionScheme.Function, actual: FunctionScheme.Function) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or
        expected.versions.len != actual.versions.len)
    {
        return error.TestExpectedEqual;
    }

    for (expected.versions, actual.versions) |exp, act| {
        try expectFunctionVersionEql(exp, act);
    }
}

fn expectFunctionVersionEql(expected: FunctionScheme.Function.Version, actual: FunctionScheme.Function.Version) !void {
    if (expected.params.len != actual.params.len) {
        return error.TestExpectedEqual;
    }

    for (expected.params, actual.params) |exp, act| {
        try expectTypeEql(exp, act);
    }

    try expectTypeEql(expected.return_type, actual.return_type);
}

fn expectObjectSchemeEql(expected: ObjectScheme, actual: ObjectScheme) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or expected.objects.len != actual.objects.len) {
        return error.TestExpectedEqual;
    }

    for (expected.objects, actual.objects) |exp, act| {
        try expectObjectEql(exp, act);
    }
}

fn expectObjectEql(expected: ObjectScheme.Object, actual: ObjectScheme.Object) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or expected.versions.len != actual.versions.len) {
        return error.TestExpectedEqual;
    }

    for (expected.versions, actual.versions) |exp, act| {
        if (!Type.eql(exp, act)) {
            return error.TestExpectedEqual;
        }
    }
}

fn expectTypeEql(expected: ?Type, actual: ?Type) !void {
    // uses the `FieldType.eql` implementation since it does everything, including chasing pointers.
    if (!Type.eql(expected, actual)) {
        return error.TestExpectedEqual;
    }
}
