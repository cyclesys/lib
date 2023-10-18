const std = @import("std");
const meta = @import("../meta.zig");
const define = @import("define.zig");
const Type = @import("type.zig").Type;

name: []const u8,
objects: []const Object,

const Self = @This();

pub const Object = struct {
    name: []const u8,
    versions: []const Type,

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

    fn merge(comptime left: Object, comptime right: Object) Object {
        comptime {
            var versions = left.versions;
            outer: for (right.versions) |r| {
                for (versions) |l| {
                    if (Type.eql(l, r)) {
                        continue :outer;
                    }
                }
                versions = versions ++ &[_]Type{r};
            }
            return Object{
                .name = left.name,
                .versions = versions,
            };
        }
    }
};

pub fn from(comptime Scheme: type) Self {
    if (Scheme.kind != .object) {
        @compileError("scheme is not an object scheme");
    }

    const result = comptime blk: {
        var objects: [Scheme.types.len]Object = undefined;
        for (Scheme.types, 0..) |T, i| {
            objects[i] = Object.from(T);
        }
        break :blk Self{
            .name = Scheme.name,
            .objects = objects[0..],
        };
    };

    return result;
}

pub fn dependencies(comptime Scheme: type) []const type {
    comptime {
        var result: []const type = &[_]type{};
        for (Scheme.types) |T| {
            for (T.versions) |Ver| {
                var deps: []const type = &[_]type{};
                for (Self.types(Ver)) |Dep| {
                    if (Dep == Scheme)
                        continue;

                    deps = meta.mergeTypes(deps, &[_]type{Dep});
                    deps = meta.mergeTypes(deps, Self.dependencies(Dep));
                }
                result = meta.mergeTypes(result, deps);
            }
        }
        return result;
    }
}

fn types(comptime T: type) []const type {
    comptime {
        switch (@typeInfo(T)) {
            .Void, .Bool, .Int, .Float, .Enum => {
                return &[_]type{};
            },
            .Optional => |info| {
                return Self.types(info.child);
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
                            return Self.types(T.child);
                        },
                        .map => {
                            return meta.mergeTypes(
                                Self.types(T.key),
                                Self.types(T.value),
                            );
                        },
                        else => @compileError("unexpected field type"),
                    }
                } else {
                    var result: []const type = &[_]type{};
                    for (info.fields) |field| {
                        result = meta.mergeTypes(result, Self.types(field.type));
                    }
                    return result;
                }
            },
            .Union => |info| {
                var result: []const type = &[_]type{};
                for (info.fields) |field| {
                    result = meta.mergeTypes(result, Self.types(field.type));
                }
                return result;
            },
            .Fn => |info| {
                var result: []const type = &[_]type{};
                for (info.params) |param| {
                    result = meta.mergeTypes(result, Self.types(param.type.?));
                }
                result = meta.mergeTypes(result, Self.types(info.return_type.?));
                return result;
            },
            else => @compileError("unexpected field type"),
        }
    }
}

pub fn mergeSchemes(comptime schemes: []const Self) []const Self {
    const result = comptime blk: {
        var merged_schemes: [schemes.len]Self = undefined;
        var len = 0;
        outer: for (schemes) |scheme| {
            for (merged_schemes[0..len], 0..) |merged, i| {
                if (std.mem.eql(u8, merged.name, scheme.name)) {
                    merged_schemes[i] = Self.merge(merged, scheme);
                    continue :outer;
                }
            }

            merged_schemes[len] = scheme;
            len += 1;
        }
        break :blk merged_schemes[0..len];
    };
    return result;
}

fn merge(comptime left: Self, comptime right: Self) Self {
    const result = comptime blk: {
        var objects: [left.objects.len + right.objects.len]Object = undefined;
        for (left.objects, 0..) |obj, i| {
            objects[i] = obj;
        }
        var len = left.objects.len;

        outer: for (right.objects) |right_obj| {
            for (left.objects, 0..) |left_obj, i| {
                if (std.mem.eql(u8, left_obj.name, right_obj.name)) {
                    objects[i] = Object.merge(left_obj, right_obj);
                    continue :outer;
                }
            }
            objects[len] = right_obj;
            len += 1;
        }
        break :blk Self{
            .name = left.name,
            .objects = objects[0..len],
        };
    };
    return result;
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
        Self.Object.from(Obj),
    );
}

test "object scheme" {
    const Objs = define.Scheme("scheme/objs", .{
        define.Object("One", .{
            bool,
        }),
    });

    try expectSelfEql(
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
        Self.from(Objs(define.This)),
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

    const expected: []const Self = &.{
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

    const deps = Self.dependencies(Objs(define.This));
    inline for (deps, 0..) |dep, i| {
        const actual = Self.from(dep);
        try expectSelfEql(expected[i], actual);
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

    const expected: []const Self = &.{
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
        var schemes: []const Self = &[_]Self{};
        for (Self.dependencies(Objs(define.This))) |dep| {
            schemes = schemes ++ &[_]Self{Self.from(dep)};
        }
        break :blk Self.mergeSchemes(schemes);
    };

    inline for (expected, actual) |exp, act| {
        try expectSelfEql(exp, act);
    }
}

fn expectSelfEql(expected: Self, actual: Self) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or expected.objects.len != actual.objects.len) {
        return error.TestExpectedEqual;
    }

    for (expected.objects, actual.objects) |exp, act| {
        try expectObjectEql(exp, act);
    }
}

fn expectObjectEql(expected: Self.Object, actual: Self.Object) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or expected.versions.len != actual.versions.len) {
        return error.TestExpectedEqual;
    }

    for (expected.versions, actual.versions) |exp, act| {
        if (!Type.eql(exp, act)) {
            return error.TestExpectedEqual;
        }
    }
}
