const std = @import("std");

pub fn serialize(value: anytype, writer: anytype) !void {
    const Type = @TypeOf(value);
    switch (@typeInfo(Type)) {
        .Type,
        .NoReturn,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .ErrorUnion,
        .ErrorSet,
        .Fn,
        .Opaque,
        .Frame,
        .AnyFrame,
        .Vector,
        .EnumLiteral,
        => @compileError("cannot serialize type: " ++ @typeName(Type)),
        .Void => {
            // do nothing
        },
        .Bool, .Int, .Float => {
            try writePacked(value, writer);
        },
        .Pointer => |info| {
            if (info.child != u8) {
                @compileError("can only serialize pointer to byte(s)");
            }

            switch (info.size) {
                .Many, .C => {
                    @compileError("can only serialize pointer with known size");
                },
                .One => {
                    try writer.writeByte(value.*);
                },
                .Slice => {
                    try writePacked(value.len, writer);
                    try writer.writeAll(value);
                },
            }
        },
        .Array => {
            for (value) |elem| {
                try serialize(elem, writer);
            }
        },
        .Struct => |info| {
            inline for (info.fields) |field| {
                if (field.is_comptime) {
                    @compileError("cannot serialize comptime struct fields");
                }

                try serialize(@field(value, field.name), writer);
            }
        },
        .Optional => {
            if (value) |v| {
                try writer.writeByte(1);
                try serialize(v, writer);
            } else {
                try writer.writeByte(0);
            }
        },
        .Enum => {
            try writePacked(@intFromEnum(value), writer);
        },
        .Union => |info| {
            if (info.tag_type == null) {
                @compileError("cannot serialize untagged union types");
            }

            switch (value) {
                inline else => |val, tag| {
                    try writePacked(@intFromEnum(tag), writer);
                    try serialize(val, writer);
                },
            }
        },
    }
}

fn writePacked(value: anytype, writer: anytype) !void {
    const Type = @TypeOf(value);
    var bytes: []const u8 = undefined;
    bytes.ptr = @ptrCast(&value);
    bytes.len = @sizeOf(Type);
    try writer.writeAll(bytes);
}

pub fn deserialize(comptime Type: type, bytes: []const u8) !Type {
    var reader = Reader{ .bytes = bytes };
    return deserializeImpl(Type, &reader);
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn readByte(self: *Reader) !*const u8 {
        if (self.pos + 1 > self.bytes.len) {
            return error.EndOfStream;
        }

        const ptr = &self.bytes[self.pos];
        self.pos += 1;

        return ptr;
    }

    fn readBytes(self: *Reader, len: usize) !*const u8 {
        if (self.pos + len > self.bytes.len) {
            return error.EndOfStream;
        }

        const ptr = &self.bytes[self.pos];
        self.pos += len;

        return ptr;
    }
};

fn deserializeImpl(comptime Type: type, reader: *Reader) !Type {
    switch (@typeInfo(Type)) {
        .Type,
        .NoReturn,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .ErrorUnion,
        .ErrorSet,
        .Fn,
        .Opaque,
        .Frame,
        .AnyFrame,
        .Vector,
        .EnumLiteral,
        => @compileError("can't deserialize type: " ++ @typeName(Type)),
        .Void => {
            // do nothing
        },
        .Bool => {
            const value = try reader.readByte();
            return switch (value.*) {
                1 => true,
                0 => false,
                else => error.InvalidBool,
            };
        },
        .Int, .Float => {
            return readPacked(Type, reader);
        },
        .Pointer => |info| {
            if (info.child != u8) {
                @compileError("can only deserialize pointer to byte(s)");
            }

            switch (info.size) {
                .Many, .C => {
                    @compileError("can only deserialize pointer with known size");
                },
                .One => {
                    return reader.readByte();
                },
                .Slice => {
                    var bytes: []const u8 = undefined;
                    bytes.len = try readPacked(usize, reader);
                    bytes.ptr = @ptrCast(try reader.readBytes(bytes.len));
                    return bytes;
                },
            }
        },
        .Array => |info| {
            var out: Type = undefined;
            for (0..info.len) |i| {
                out[i] = try deserializeImpl(info.child, reader);
            }
            return out;
        },
        .Struct => |info| {
            var out: Type = undefined;
            inline for (info.fields) |field| {
                @field(out, field.name) = try deserializeImpl(field.type, reader);
            }
            return out;
        },
        .Optional => |info| {
            const value = try reader.readByte();
            return switch (value.*) {
                1 => try deserializeImpl(info.child, reader),
                0 => null,
                else => {
                    std.log.warn("InvalidOptional {}", .{value.*});
                    return error.InvalidOptional;
                },
            };
        },
        .Enum => |info| {
            const value = try readPacked(info.tag_type, reader);
            return @enumFromInt(value);
        },
        .Union => |info| {
            if (info.tag_type == null) {
                @compileError("cannot deserialize untagged union types");
            }

            const TagInt = std.meta.Tag(info.tag_type.?);
            const tag_int = try readPacked(TagInt, reader);
            switch (@as(info.tag_type.?, @enumFromInt(tag_int))) {
                inline else => |tag| {
                    var out = @unionInit(Type, @tagName(tag), undefined);
                    const FieldType = @TypeOf(@field(out, @tagName(tag)));
                    @field(out, @tagName(tag)) = try deserializeImpl(FieldType, reader);
                    return out;
                },
            }
        },
    }
}

fn readPacked(comptime Type: type, reader: *Reader) !Type {
    var bytes = try reader.readBytes(@sizeOf(Type));
    const ptr: *align(1) const Type = @ptrCast(bytes);
    return ptr.*;
}

const ByteList = std.ArrayList(u8);

fn serde(comptime Type: type, value: Type) !Type {
    var buf = ByteList.init(std.testing.allocator);
    defer buf.deinit();
    try serialize(value, buf.writer());
    return deserialize(Type, buf.items);
}

fn serdeLeak(comptime Type: type, value: Type) !struct { []const u8, Type } {
    var buf = ByteList.init(std.testing.allocator);
    try serialize(value, buf.writer());

    var bytes = try buf.toOwnedSlice(); // leaked, must be freed by caller
    return .{ bytes, try deserialize(Type, bytes) };
}

test "bool serde" {
    try std.testing.expectEqual(true, try serde(bool, true));
    try std.testing.expectEqual(false, try serde(bool, false));
}

test "int serde" {
    try std.testing.expectEqual(@as(i8, -10), try serde(i8, -10));
    try std.testing.expectEqual(@as(i16, -20), try serde(i16, -20));
    try std.testing.expectEqual(@as(i32, -30), try serde(i32, -30));
    try std.testing.expectEqual(@as(i64, -40), try serde(i64, -40));
    try std.testing.expectEqual(@as(i89, -50), try serde(i89, -50));

    try std.testing.expectEqual(@as(u8, 10), try serde(u8, 10));
    try std.testing.expectEqual(@as(u16, 20), try serde(u16, 20));
    try std.testing.expectEqual(@as(u32, 30), try serde(u32, 30));
    try std.testing.expectEqual(@as(u64, 40), try serde(u64, 40));
    try std.testing.expectEqual(@as(u89, 50), try serde(u89, 50));
}

test "float serde" {
    try std.testing.expectEqual(@as(f16, -10.0), try serde(f16, -10.0));
    try std.testing.expectEqual(@as(f32, 10.0), try serde(f32, 10.0));
    try std.testing.expectEqual(@as(f64, -20.0), try serde(f64, -20.0));
    try std.testing.expectEqual(@as(f80, 20.0), try serde(f80, 20.0));
    try std.testing.expectEqual(@as(f128, -30.0), try serde(f128, -30.0));
}

test "pointer serde" {
    const result = try serdeLeak(*const u8, &@as(u8, 10));
    defer std.testing.allocator.destroy(result[0]);

    try std.testing.expectEqual(result[1].*, 10);
}

test "slice serde" {
    const result = try serdeLeak([]const u8, &[_]u8{ 10, 50, 100, 150, 200 });
    defer std.testing.allocator.free(result[0]);

    try std.testing.expectEqualDeep(@as([]const u8, &[_]u8{ 10, 50, 100, 150, 200 }), result[1]);
}

test "array serde" {
    try std.testing.expectEqualDeep([_]u8{ 10, 50, 100, 150, 200 }, try serde([5]u8, [_]u8{ 10, 50, 100, 150, 200 }));
}

test "struct serde" {
    const Struct = struct {
        field1: u8,
        field2: u16,
    };
    try std.testing.expectEqualDeep(Struct{
        .field1 = 99,
        .field2 = 199,
    }, try serde(Struct, Struct{
        .field1 = 99,
        .field2 = 199,
    }));
}

test "optional serde" {
    try std.testing.expectEqual(@as(?bool, null), try serde(?bool, null));
    try std.testing.expectEqual(@as(?bool, true), try serde(?bool, true));
}

test "unsized enum serde" {
    const Enum = enum {
        Field1,
        Field2,
    };
    try std.testing.expectEqual(Enum.Field1, try serde(Enum, .Field1));
    try std.testing.expectEqual(Enum.Field2, try serde(Enum, .Field2));
}

test "sized enum serde" {
    const Enum = enum(u24) {
        Field1 = 100,
        Field2 = 200,
    };
    try std.testing.expectEqual(Enum.Field1, try serde(Enum, .Field1));
    try std.testing.expectEqual(Enum.Field2, try serde(Enum, .Field2));
}

test "tagged union serde" {
    const Union = union(enum) {
        Tag1: u16,
        Tag2: u32,
        Tag3: u64,
    };
    try std.testing.expectEqual(Union{ .Tag1 = 199 }, try serde(Union, .{ .Tag1 = 199 }));
    try std.testing.expectEqual(Union{ .Tag2 = 1999 }, try serde(Union, .{ .Tag2 = 1999 }));
    try std.testing.expectEqual(Union{ .Tag3 = 19999 }, try serde(Union, .{ .Tag3 = 19999 }));
}
