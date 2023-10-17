const std = @import("std");

const DefKind = enum {
    scheme,
    object,
    function,
    command,
    this,
    ref,
    array,
    list,
    map,
    string,
    ignore,
};

pub const SchemeFn = fn (comptime anytype) type;

pub fn Scheme(comptime scheme_name: []const u8, comptime scheme_types: anytype) SchemeFn {
    if (scheme_types.len == 0) {
        @compileError("`types` cannot be empty");
    }

    comptime var scheme_kind: ?DefKind = null;
    for (scheme_types, 0..) |Type, i| {
        if (!@hasDecl(Type, "def_kind")) {
            @compileError("`types` can only contain `Object`, `Function`, or `Command` types");
        }

        switch (Type.def_kind) {
            .object, .function, .command => {},
            else => @compileError("`types` can only contain `Object`, `Function`, or `Command` types"),
        }

        if (scheme_kind != null and (Type.def_kind != scheme_kind.?)) {
            @compileError("`types` can only types of the same kind " ++
                "(i.e. if it has `Object` types it can only contain `Object` types, etc.)");
        }

        for (0..i) |ii| {
            if (std.mem.eql(u8, scheme_types[ii].name, Type.name)) {
                @compileError("duplicate type name found: " ++ Type.name);
            }
        }

        scheme_kind = Type.def_kind;
    }

    for (scheme_types) |Type| {
        switch (Type.def_kind) {
            .object => checkObject(Type.versions, scheme_types),
            .function => checkFunction(Type.versions),
            .command => checkCommandType(Type.cmd_type),
            else => unreachable,
        }
    }

    return struct {
        pub const def_kind = DefKind.scheme;
        pub const kind = scheme_kind.?;
        pub const name = scheme_name;
        pub const types = scheme_types;

        const Self = @This();

        pub fn get(comptime arg: anytype) type {
            if (@TypeOf(arg) == @TypeOf(This) and arg == This) {
                return Self;
            }

            for (types) |Type| {
                if (std.mem.eql(u8, Type.name, arg)) {
                    return struct {
                        pub const def_kind = DefKind.ref;
                        pub const def = Type;
                        pub const scheme = Self;
                    };
                }
            }

            @compileError(arg ++ " is not defined in this scheme");
        }
    }.get;
}

pub fn Object(comptime object_name: []const u8, comptime object_versions: anytype) type {
    return struct {
        pub const def_kind = DefKind.object;
        pub const name = object_name;
        pub const versions = object_versions;
    };
}

pub fn Function(comptime function_name: []const u8, comptime function_versions: anytype) type {
    return struct {
        pub const def_kind = DefKind.function;
        pub const name = function_name;
        pub const versions = function_versions;
    };
}

pub fn Command(comptime command_name: []const u8, comptime Type: type) type {
    return struct {
        pub const def_kind = DefKind.command;
        pub const name = command_name;
        pub const cmd_type = Type;
    };
}

pub fn This(comptime type_name: []const u8) type {
    return struct {
        pub const def_kind = DefKind.this;
        pub const name = type_name;
    };
}

pub fn Array(comptime length: comptime_int, comptime Child: type) type {
    return struct {
        pub const def_kind = DefKind.array;
        pub const len = length;
        pub const child = Child;
    };
}

pub fn List(comptime Child: type) type {
    return struct {
        pub const def_kind = DefKind.list;
        pub const child = Child;
    };
}

pub fn Map(comptime Key: type, comptime Value: type) type {
    return struct {
        pub const def_kind = DefKind.map;
        pub const key = Key;
        pub const value = Value;
    };
}

pub const String = struct {
    pub const def_kind = DefKind.string;
};

pub const Ignore = struct {
    pub const def_kind = DefKind.ignore;
};

fn checkObject(comptime versions: anytype, comptime scheme_types: anytype) void {
    for (versions) |Ver| {
        checkField(Ver, scheme_types, false);
    }
}

fn checkFunction(comptime versions: anytype) void {
    for (versions) |Ver| {
        switch (@typeInfo(Ver)) {
            .Fn => |fn_info| {
                for (fn_info.params) |param_info| {
                    if (param_info.type == null) {
                        @compileError("field is invalid");
                    }

                    checkField(param_info.type.?, .{}, false);
                }

                checkField(fn_info.return_type.?, .{}, false);
            },
            else => @compileError("`Function` type can only contain `fn` types"),
        }
    }
}

fn checkField(
    comptime Field: type,
    comptime scheme_types: anytype,
    comptime allow_ignore: bool,
) void {
    switch (@typeInfo(Field)) {
        .Type => @compileError("field cannot be type."),
        .NoReturn => @compileError("field cannot be noreturn"),
        .Pointer => @compileError("field cannot be pointer"),
        .Array => @compileError("field cannot be native array, use `Array` type instead."),
        .ComptimeFloat => @compileError("field cannot be comptime_float"),
        .ComptimeInt => @compileError("field cannot be comptime_int"),
        .Undefined => @compileError("field cannot be undefined"),
        .Null => @compileError("field cannot be null"),
        .ErrorUnion => @compileError("field cannot be error union"),
        .ErrorSet => @compileError("field cannot be error set"),
        .Fn => @compileError("field cannot be fn"),
        .Opaque => @compileError("field cannot be opaque"),
        .Frame => @compileError("field cannot be frame"),
        .AnyFrame => @compileError("field cannot be anyframe"),
        .Vector => @compileError("field cannot be vector"),
        .EnumLiteral => @compileError("field cannot be enum literal"),
        .Void, .Bool, .Int, .Float, .Enum => {
            // these types are valid
        },
        .Optional => |info| {
            checkField(info.child, scheme_types, false);
        },
        .Struct => |info| {
            if (@hasDecl(Field, "def_kind")) {
                switch (Field.def_kind) {
                    .scheme => @compileError("field cannot be `Scheme` type"),
                    .object => @compileError("field cannot be `Object` type"),
                    .function => @compileError("field cannot be `Function` type"),
                    .command => @compileError("field cannot be `Command` type"),
                    .this => {
                        if (scheme_types.len == 0) {
                            @compileError("field cannot be `This` type");
                        }

                        for (scheme_types) |T| {
                            if (std.mem.eql(u8, T.name, Field.name)) {
                                break;
                            }
                        } else {
                            @compileError(Field.name ++ " is not defined in the scheme referenced by `This`.");
                        }
                    },
                    .ref => {
                        checkRef(Field);
                    },
                    .array => {
                        checkField(Field.child, scheme_types, false);
                    },
                    .list => {
                        checkField(Field.child, scheme_types, false);
                    },
                    .map => {
                        checkField(Field.key, scheme_types, false);
                        checkField(Field.value, scheme_types, false);
                    },
                    .string => {
                        // valid
                    },
                    .ignore => {
                        if (!allow_ignore) {
                            @compileError("field cannot be `Ignore` type");
                        }
                    },
                }
            } else {
                for (info.fields) |field| {
                    if (field.is_comptime) {
                        @compileError("struct fields cannot be comptime.");
                    }

                    checkField(field.type, scheme_types, true);
                }
            }
        },
        .Union => |info| {
            if (info.tag_type == null) {
                @compileError("field union types must be tagged");
            }
            for (info.fields) |field| {
                checkField(field.type, scheme_types, true);
            }
        },
    }
}

fn checkCommandType(comptime Field: type) void {
    switch (@typeInfo(Field)) {
        .Struct => |info| {
            if (@hasDecl(Field, "def_kind")) {
                switch (Field.def_kind) {
                    .array => {
                        checkCommandType(Field.child);
                    },
                    .list => {
                        checkCommandType(Field.child);
                    },
                    .ref => {
                        checkRef(Field);
                    },
                    else => {
                        @compileError("invalid Command field");
                    },
                }
            } else {
                for (info.fields) |field| {
                    checkCommandType(field.type);
                }
            }
        },
        .Union => |info| {
            if (info.tag_type == null) {
                @compileError("field union types must be tagged");
            }

            for (info.fields) |field| {
                if (field.type == void) continue;
                checkCommandType(field.type);
            }
        },
        else => @compileError("invalid `Command` field"),
    }
}

fn checkRef(comptime Ref: type) void {
    switch (Ref.def.def_kind) {
        .object => {
            // valid
        },
        .function => {
            @compileError("field cannot be `Function` ref type");
        },
        .command => {
            @compileError("field cannot be `Command` ref type");
        },
        else => unreachable,
    }
}
