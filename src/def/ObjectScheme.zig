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
                for (versions[0..i]) |prev_version| {
                    if (Type.eql(versions[i], prev_version)) {
                        @compileError("duplicate type found in object: " ++ T.name);
                    }
                }
            }
            break :blk Object{
                .name = T.name,
                .versions = versions[0..],
            };
        };
        return result;
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
            for (objects[0..i]) |prev_obj| {
                if (std.mem.eql(u8, objects[i].name, prev_obj.name)) {
                    @compileError("duplicate objects found in object scheme: " ++ Scheme.name);
                }
            }
        }
        break :blk Self{
            .name = Scheme.name,
            .objects = objects[0..],
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
        Self.from(Objs),
    );
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
