const std = @import("std");

pub fn View(comptime Type: type) type {
    return switch (@typeInfo(Type)) {
        .Void, .Bool, .Int, .Float, .Enum => Type,
        .Pointer => PointerView(Type),
        .Array => ArrayView(Type),
        .Struct => StructView(Type),
        .Optional => |info| ?View(info.child),
        .Union => UnionView(Type),
        else => @compileError("unsupported type"),
    };
}

fn PointerView(comptime Type: type) type {
    const info = @typeInfo(Type).Pointer;
    return switch (info.size) {
        .One => View(info.child),
        .Slice => if (info.child == u8)
            []const u8
        else
            SliceView(Type),
        else => @compileError("unsupported pointer type"),
    };
}

fn SliceView(comptime Type: type) type {
    return struct {
        bytes: []const u8,

        const Element = @typeInfo(Type).Pointer.child;
        const Self = @This();

        pub fn len(self: Self) usize {
            return readPacked(usize, self.bytes);
        }

        pub fn elem(self: Self, index: usize) View(Element) {
            const offset = @sizeOf(usize);
            return readElem(Element, self.len(), index, self.bytes[offset..]);
        }
    };
}

fn ArrayView(comptime Type: type) type {
    return struct {
        bytes: []const u8,

        const Element = @typeInfo(Type).Array.child;
        const Self = @This();

        pub fn elem(self: Self, index: usize) View(Element) {
            const len = @typeInfo(Type).Array.len;
            return readElem(Element, len, index, self.bytes);
        }
    };
}

fn StructView(comptime Type: type) type {
    return struct {
        bytes: []const u8,

        const Self = @This();

        const FieldName = if (@typeInfo(Type).Struct.is_tuple)
            comptime_int
        else
            std.meta.FieldEnum(Type);

        fn FieldType(comptime name: FieldName) type {
            const info = @typeInfo(Type).Struct;
            const field_index = if (info.is_tuple) name else @intFromEnum(name);
            return info.fields[field_index].type;
        }

        fn fieldIndex(comptime name: FieldName) comptime_int {
            return if (@typeInfo(Type).Struct.is_tuple)
                name
            else
                @intFromEnum(name);
        }

        pub fn field(self: Self, comptime name: FieldName) View(FieldType(name)) {
            // Skip past all the preceding fields
            var offset: usize = 0;
            inline for (0..fieldIndex(name)) |_| {
                const field_size = readPacked(usize, self.bytes[offset..]);
                offset += @sizeOf(usize);
                offset += field_size;
            }
            offset += @sizeOf(usize);

            return read(FieldType(name), self.bytes[offset..]);
        }
    };
}

fn UnionView(comptime Type: type) type {
    return struct {
        bytes: []const u8,

        pub const Tag = blk: {
            const info = @typeInfo(Type).Union;
            break :blk info.tag_type orelse @compileError("only tagged unions are supported");
        };
        const TagInt = blk: {
            const info = @typeInfo(Tag).Enum;
            break :blk info.tag_type;
        };
        const tag_size = @sizeOf(TagInt);
        const Self = @This();

        pub fn Value(comptime t: Tag) type {
            comptime {
                const info = @typeInfo(Type).Union;
                for (info.fields) |field| {
                    if (std.mem.eql(u8, field.name, @tagName(t))) {
                        return field.type;
                    }
                }
                unreachable;
            }
        }

        pub fn tag(self: Self) Tag {
            return readEnum(Tag, self.bytes);
        }

        pub fn value(self: Self, comptime t: Tag) View(Value(t)) {
            return read(Value(t), self.bytes[tag_size..]);
        }
    };
}

pub fn read(comptime Type: type, bytes: []const u8) View(Type) {
    return switch (@typeInfo(Type)) {
        .Void => {},
        .Bool, .Int, .Float => readPacked(Type, bytes),
        .Optional => readOptional(Type, bytes),
        .Pointer => readPointer(Type, bytes),
        .Array => ArrayView(Type){ .bytes = bytes },
        .Struct => StructView(Type){ .bytes = bytes },
        .Enum => readEnum(Type, bytes),
        .Union => UnionView(Type){ .bytes = bytes },
        else => @compileError("unsupported"),
    };
}

fn readOptional(comptime Type: type, bytes: []const u8) View(Type) {
    const info = @typeInfo(Type).Optional;
    return if (bytes[0] == 1) read(info.child, bytes[1..]) else null;
}

fn readPointer(comptime Type: type, bytes: []const u8) View(Type) {
    const info = @typeInfo(Type).Pointer;
    return switch (info.size) {
        .One => read(info.child, bytes),
        .Slice => if (info.child == u8)
            readByteSlice(bytes)
        else
            SliceView(Type){
                .bytes = bytes,
            },
        else => @compileError("unsupported pointer type"),
    };
}

fn readByteSlice(bytes: []const u8) []const u8 {
    const offset = @sizeOf(usize);
    const len = readPacked(usize, bytes);
    return bytes[offset..][0..len];
}

fn readElem(comptime Element: type, len: usize, index: usize, bytes: []const u8) View(Element) {
    if (index >= len) {
        @panic("index out of bounds");
    }

    // add up the sizes of all the preceding elements
    var total_skip: usize = 0;
    for (0..index) |i| {
        const size_offset = i * @sizeOf(usize);
        total_skip += readPacked(usize, bytes[size_offset..]);
    }

    // The size of the element sizes slice
    const sizes_size = @sizeOf(usize) * len;

    // the offset is the size of the element sizes slice and the size of all the preceding elements
    const offset = sizes_size + total_skip;

    return read(Element, bytes[offset..]);
}

fn readEnum(comptime Type: type, bytes: []const u8) Type {
    // The integer value is read and then converted to the enum type
    const Int = @typeInfo(Type).Enum.tag_type;
    const t = readPacked(Int, bytes);
    return @enumFromInt(t);
}

fn readPacked(comptime Type: type, bytes: []const u8) Type {
    var value_bytes = bytes[0..@sizeOf(Type)];
    const ptr: *align(1) const Type = @ptrCast(value_bytes);
    return ptr.*;
}

pub fn write(value: anytype, out: *std.ArrayList(u8)) !void {
    _ = try writeValue(@TypeOf(value), std.mem.Allocator.Error, value, out);
}

// Writes a value of type `Type` by calling methods on `adapter` to get the value(s) expected of `Type`.
pub fn writeAdapted(comptime Type: type, comptime Error: type, adapter: anytype, out: *std.ArrayList(u8)) !void {
    _ = try writeValue(Type, Error || std.mem.Allocator.Error, adapter, out);
}

fn writeValue(comptime Type: type, comptime Error: type, value: anytype, out: *std.ArrayList(u8)) Error!usize {
    return switch (@typeInfo(Type)) {
        .Void => 0,
        .Bool, .Int, .Float => try writePrimitive(Type, Error, value, out),
        .Optional => try writeOptional(Type, Error, value, out),
        .Pointer => try writePointer(Type, Error, value, out),
        .Array => |info| try writeElements(Type, info.child, Error, info.len, value, out),
        .Struct => try writeStruct(Type, Error, value, out),
        .Enum => try writeEnum(Type, Error, value, out),
        .Union => try writeUnion(Type, Error, value, out),
        else => @compileError("unsupported type"),
    };
}

fn writePrimitive(comptime Type: type, comptime Error: type, value: anytype, out: *std.ArrayList(u8)) Error!usize {
    const is_adapter = @TypeOf(value) != Type;
    // Primitives have all of their bytes written as-is
    return try writePacked(if (is_adapter) try value.value() else value, null, out);
}

fn writeOptional(comptime Type: type, comptime Error: type, value: anytype, out: *std.ArrayList(u8)) Error!usize {
    const is_adapter = @TypeOf(value) != Type;
    const info = @typeInfo(Type).Optional;

    // The first byte that is written signifies whether there is a value or not
    // 1 == Some
    // 0 == None
    const opt_val = if (is_adapter) try value.value() else value;
    return if (opt_val) |v|
        try writePacked(@as(u8, 1), null, out) + try writeValue(info.child, Error, v, out)
    else
        try writePacked(@as(u8, 0), null, out);
}

fn writePointer(comptime Type: type, comptime Error: type, value: anytype, out: *std.ArrayList(u8)) Error!usize {
    const is_adapter = @TypeOf(value) != Type;
    const info = @typeInfo(Type).Pointer;
    return switch (info.size) {
        // Single value pointers are simply dereferenced and their value written
        .One => try writeValue(info.child, Error, if (is_adapter) value else value.*, out),

        .Slice => blk: {
            if (info.child == u8) {
                // Byte slices are written as-is
                const bytes = if (is_adapter) try value.value() else value;
                const size = try writePacked(bytes.len, null, out);
                try out.appendSlice(bytes);
                break :blk size + bytes.len;
            } else {
                // All other slices are written element by element
                const len = if (is_adapter) try value.len() else value.len;
                break :blk try writePacked(len, null, out) +
                    try writeElements(Type, info.child, Error, len, value, out);
            }
        },
        else => @compileError("unsupported pointer type"),
    };
}

fn writeElements(
    comptime Type: type,
    comptime Element: type,
    comptime Error: type,
    len: usize,
    value: anytype,
    out: *std.ArrayList(u8),
) Error!usize {
    const is_adapter = @TypeOf(value) != Type;

    // Allocate the memory for the element sizes
    const sizes_start = out.items.len;
    const sizes_size = len * @sizeOf(usize);
    try out.appendNTimes(0, sizes_size);

    var elems_size: usize = 0;
    for (0..len) |i| {
        const elem = if (is_adapter) try value.elem(i) else value[i];

        // Append the element, and record its size
        const size = try writeValue(Element, Error, elem, out);
        elems_size += size;

        // Write the element's size into the previously allocated element size memory
        const size_offset = sizes_start + (i * @sizeOf(usize));
        _ = try writePacked(size, size_offset, out);
    }

    // The total size is the size of the element size list, and the size of the elements themselves
    return sizes_size + elems_size;
}

fn writeStruct(
    comptime Type: type,
    comptime Error: type,
    value: anytype,
    out: *std.ArrayList(u8),
) Error!usize {
    const is_adapter = @TypeOf(value) != Type;
    const info = @typeInfo(Type).Struct;

    var size: usize = 0;
    inline for (info.fields, 0..) |field, i| {
        // Allocate the memory for the field's size
        const field_size_offset = out.items.len;
        size += try writePacked(@as(usize, 0), null, out);

        // Write the field value
        const field_value = if (is_adapter) try value.field(i) else @field(value, field.name);
        const field_size = try writeValue(field.type, Error, field_value, out);

        // Write the field value's size into the previously allocated memory
        _ = try writePacked(field_size, field_size_offset, out);
        size += field_size;
    }

    return size;
}

fn writeEnum(comptime Type: type, comptime Error: type, value: anytype, out: *std.ArrayList(u8)) Error!usize {
    const is_adapter = @TypeOf(value) != Type;
    const enum_value = if (is_adapter) try value.value() else value;

    // The enum value is written as its integer value
    return try writePacked(@intFromEnum(enum_value), null, out);
}

fn writeUnion(
    comptime Type: type,
    comptime Error: type,
    value: anytype,
    out: *std.ArrayList(u8),
) Error!usize {
    const is_adapter = @TypeOf(value) != Type;
    const Tag = std.meta.Tag(Type);
    const info = @typeInfo(Type).Union;

    const tag: Tag = if (is_adapter) try value.tag() else value;
    switch (tag) {
        inline else => |t| {
            // Write the active tag
            var size = try writeEnum(Tag, Error, t, out);

            // Write the active value
            const field = info.fields[@intFromEnum(t)];
            const field_value = if (is_adapter) try value.value(t) else @field(value, field.name);
            size += try writeValue(field.type, Error, field_value, out);

            return size;
        },
    }
}

fn writePacked(value: anytype, at: ?usize, out: *std.ArrayList(u8)) !usize {
    const Type = @TypeOf(value);
    var bytes: []const u8 = undefined;
    bytes.ptr = @ptrCast(&value);
    bytes.len = @sizeOf(Type);
    if (at) |index| {
        @memcpy(out.items[index..][0..@sizeOf(Type)], bytes);
    } else {
        try out.appendSlice(bytes);
    }
    return bytes.len;
}

test "bool serde" {
    try expectSerdeValue(true);
    try expectSerdeValue(false);

    try expectSerdeAdaptedValue(true);
    try expectSerdeAdaptedValue(false);
}

test "int serde" {
    try expectSerdeValue(@as(u8, 10));
    try expectSerdeValue(@as(i8, -10));
    try expectSerdeValue(@as(u16, 20));
    try expectSerdeValue(@as(i16, -20));
    try expectSerdeValue(@as(u32, 30));
    try expectSerdeValue(@as(i32, -30));
    try expectSerdeValue(@as(u64, 40));
    try expectSerdeValue(@as(i64, -40));
    try expectSerdeValue(@as(u89, 50));
    try expectSerdeValue(@as(i89, -50));

    try expectSerdeAdaptedValue(@as(u8, 10));
    try expectSerdeAdaptedValue(@as(i8, -10));
    try expectSerdeAdaptedValue(@as(u16, 20));
    try expectSerdeAdaptedValue(@as(i16, -20));
    try expectSerdeAdaptedValue(@as(u32, 30));
    try expectSerdeAdaptedValue(@as(i32, -30));
    try expectSerdeAdaptedValue(@as(u64, 40));
    try expectSerdeAdaptedValue(@as(i64, -40));
    try expectSerdeAdaptedValue(@as(u89, 50));
    try expectSerdeAdaptedValue(@as(i89, -50));
}

test "float serde" {
    try expectSerdeValue(@as(f16, -10.0));
    try expectSerdeValue(@as(f32, 10.0));
    try expectSerdeValue(@as(f64, -20.0));
    try expectSerdeValue(@as(f80, 20.0));
    try expectSerdeValue(@as(f128, -30.0));

    try expectSerdeAdaptedValue(@as(f16, -10.0));
    try expectSerdeAdaptedValue(@as(f32, 10.0));
    try expectSerdeAdaptedValue(@as(f64, -20.0));
    try expectSerdeAdaptedValue(@as(f80, 20.0));
    try expectSerdeAdaptedValue(@as(f128, -30.0));
}

test "pointer serde" {
    const exp = struct {
        const value: *const u32 = &100;

        fn check(result: anytype) !void {
            defer result.deinit();
            try std.testing.expectEqual(value.*, result.view);
        }
    };

    try exp.check(try serde(exp.value));
    try exp.check(try serdeAdapted(exp.value));
}

test "slice serde" {
    const exp = struct {
        const values: []const u32 = &[_]u32{ 10, 50, 100, 150, 200 };

        fn check(result: anytype) !void {
            defer result.deinit();
            try std.testing.expectEqual(values.len, result.view.len());
            for (values, 0..) |val, i| {
                try std.testing.expectEqual(val, result.view.elem(i));
            }
        }
    };

    try exp.check(try serde(exp.values));
    try exp.check(try serdeAdapted(exp.values));
}

test "slice of slices serde" {
    const exp = struct {
        const values: []const []const u32 = &[_][]const u32{
            &[_]u32{ 10, 20 },
            &[_]u32{ 30, 40, 50 },
            &[_]u32{ 60, 70, 80, 90 },
        };

        fn check(result: Serde(@TypeOf(values))) !void {
            defer result.deinit();

            try std.testing.expectEqual(values.len, result.view.len());
            for (0..values.len) |i| {
                const inner_values = values[i];
                const inner_result = result.view.elem(i);
                try std.testing.expectEqual(inner_values.len, inner_result.len());
                for (inner_values, 0..) |val, ii| {
                    try std.testing.expectEqual(val, inner_result.elem(ii));
                }
            }
        }
    };

    try exp.check(try serde(exp.values));
    try exp.check(try serdeAdapted(exp.values));
}

test "array serde" {
    const exp = struct {
        const values = [_]u32{ 10, 20, 30, 40, 50, 60, 70, 80, 90 };
        fn check(result: Serde(@TypeOf(values))) !void {
            defer result.deinit();

            for (values, 0..) |val, i| {
                try std.testing.expectEqual(val, result.view.elem(i));
            }
        }
    };

    try exp.check(try serde(exp.values));
    try exp.check(try serdeAdapted(exp.values));
}

test "array of slices" {
    const exp = struct {
        const values = [_][]const u32{
            &[_]u32{ 10, 20 },
            &[_]u32{ 30, 40, 50 },
            &[_]u32{ 60, 70, 80, 90 },
        };

        fn check(result: Serde(@TypeOf(values))) !void {
            defer result.deinit();
            for (values, 0..) |slice, i| {
                const result_slice = result.view.elem(i);
                try std.testing.expectEqual(slice.len, result_slice.len());
                for (slice, 0..) |val, ii| {
                    try std.testing.expectEqual(val, result_slice.elem(ii));
                }
            }
        }
    };

    try exp.check(try serde(exp.values));
    try exp.check(try serdeAdapted(exp.values));
}

test "struct serde" {
    const exp = struct {
        const value: struct {
            f0: ?bool = true,
            f1: ?u16 = 20,
            f2: ?u89 = 30,
            f3: ?f32 = 100.9,
        } = .{};

        fn check(result: Serde(@TypeOf(value))) !void {
            defer result.deinit();
            try std.testing.expectEqual(value.f0, result.view.field(.f0));
            try std.testing.expectEqual(value.f1, result.view.field(.f1));
            try std.testing.expectEqual(value.f2, result.view.field(.f2));
            try std.testing.expectEqual(value.f3, result.view.field(.f3));
        }
    };

    try exp.check(try serde(exp.value));
    try exp.check(try serdeAdapted(exp.value));
}

test "tuple struct serde" {
    const exp = struct {
        const value: struct {
            ?bool,
            ?u16,
            ?f32,
        } = .{ true, 89, 178.8734 };

        fn check(result: Serde(@TypeOf(value))) !void {
            defer result.deinit();
            try std.testing.expectEqual(value[0], result.view.field(0));
            try std.testing.expectEqual(value[1], result.view.field(1));
            try std.testing.expectEqual(value[2], result.view.field(2));
        }
    };

    try exp.check(try serde(exp.value));
    try exp.check(try serdeAdapted(exp.value));
}

test "struct with slices" {
    const exp = struct {
        const value: struct {
            f0: bool = true,
            f1: []const u32 = &.{ 10, 20, 30, 40 },
            f2: u89 = 100,
            f3: []const f32 = &.{ 0.99, 1.101, 2.02 },
            f4: struct {
                f0: bool = false,
                f1: []const u8 = &.{ 0, 100, 200 },
                f2: u128 = 100078230111,
                f3: []const struct {
                    f0: []const u8,
                } = &.{
                    .{ .f0 = &.{ 10, 20, 30 } },
                    .{ .f0 = &.{ 40, 50, 60 } },
                    .{ .f0 = &.{ 70, 80, 90 } },
                },
            } = .{},
        } = .{};

        fn check(result: Serde(@TypeOf(value))) !void {
            defer result.deinit();

            try std.testing.expectEqual(value.f0, result.view.field(.f0));
            for (value.f1, 0..) |val, i| {
                try std.testing.expectEqual(val, result.view.field(.f1).elem(i));
            }
            try std.testing.expectEqual(value.f2, result.view.field(.f2));
            for (value.f3, 0..) |val, i| {
                try std.testing.expectEqual(val, result.view.field(.f3).elem(i));
            }
            try std.testing.expectEqual(value.f4.f0, result.view.field(.f4).field(.f0));
            for (value.f4.f1, 0..) |val, i| {
                try std.testing.expectEqual(val, result.view.field(.f4).field(.f1)[i]);
            }
            try std.testing.expectEqual(value.f4.f2, result.view.field(.f4).field(.f2));
            try std.testing.expectEqual(value.f4.f3.len, result.view.field(.f4).field(.f3).len());
            for (value.f4.f3, 0..) |val, i| {
                const result_inner = result.view.field(.f4).field(.f3).elem(i);
                try std.testing.expectEqual(val.f0.len, result_inner.field(.f0).len);
                for (val.f0, 0..) |val2, ii| {
                    try std.testing.expectEqual(val2, result_inner.field(.f0)[ii]);
                }
            }
        }
    };

    try exp.check(try serde(exp.value));
    try exp.check(try serdeAdapted(exp.value));
}

test "optional serde" {
    try expectSerdeValue(@as(?bool, null));
    try expectSerdeValue(@as(?bool, true));
    try expectSerdeValue(@as(?f32, null));
    try expectSerdeValue(@as(?f32, 101.8721));

    try expectSerdeAdaptedValue(@as(?bool, null));
    try expectSerdeAdaptedValue(@as(?bool, true));
    try expectSerdeAdaptedValue(@as(?f32, null));
    try expectSerdeAdaptedValue(@as(?f32, 101.8721));
}

test "unsized enum serde" {
    const Enum = enum {
        Field1,
        Field2,
    };

    try expectSerdeValue(Enum.Field1);
    try expectSerdeValue(Enum.Field2);

    try expectSerdeAdaptedValue(Enum.Field1);
    try expectSerdeAdaptedValue(Enum.Field2);
}

test "sized enum serde" {
    const Enum = enum(u24) {
        Field1 = 100,
        Field2 = 10000,
    };

    try expectSerdeValue(Enum.Field1);
    try expectSerdeValue(Enum.Field2);

    try expectSerdeAdaptedValue(Enum.Field1);
    try expectSerdeAdaptedValue(Enum.Field2);
}

test "tagged union serde" {
    const exp = struct {
        const Tag = enum {
            Tag1,
            Tag2,
            Tag3,
        };
        const value: union(Tag) {
            Tag1: u16,
            Tag2: f32,
            Tag3: u64,
        } = .{
            .Tag2 = 10.1891,
        };

        fn check(result: Serde(@TypeOf(value))) !void {
            defer result.deinit();

            try std.testing.expectEqual(Tag.Tag2, result.view.tag());
            try std.testing.expectEqual(value.Tag2, result.view.value(.Tag2));
        }
    };

    try exp.check(try serde(exp.value));
    try exp.check(try serdeAdapted(exp.value));
}

fn serde(value: anytype) !Serde(@TypeOf(value)) {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    try write(value, &out);

    const bytes = try out.toOwnedSlice();
    return .{
        .view = read(@TypeOf(value), bytes),
        .bytes = bytes,
    };
}

fn serdeAdapted(value: anytype) !Serde(@TypeOf(value)) {
    var out = std.ArrayList(u8).init(std.testing.allocator);

    const Type = @TypeOf(value);
    try writeAdapted(Type, error{}, Adapter(Type).init(value), &out);

    const bytes = try out.toOwnedSlice();
    return .{
        .view = read(Type, bytes),
        .bytes = bytes,
    };
}

fn expectSerdeValue(value: anytype) !void {
    const result = try serde(value);
    defer result.deinit();
    try std.testing.expectEqual(value, result.view);
}

fn expectSerdeAdaptedValue(value: anytype) !void {
    const result = try serdeAdapted(value);
    defer result.deinit();
    try std.testing.expectEqual(value, result.view);
}

fn Serde(comptime Type: type) type {
    return struct {
        view: View(Type),
        bytes: []const u8,

        const Self = @This();

        fn deinit(self: Self) void {
            std.testing.allocator.free(self.bytes);
        }
    };
}

fn Adapter(comptime Type: type) type {
    return switch (@typeInfo(Type)) {
        .Void, .Bool, .Int, .Float, .Enum => ValueAdapter(Type),
        .Pointer => |info| switch (info.size) {
            .One => PointerAdapter(info.child),
            .Slice => if (info.child == u8)
                ValueAdapter(Type)
            else
                SliceAdapter(info.child),
            else => @compileError(""),
        },
        .Array => |info| ArrayAdapter(info.child, info.len),
        .Struct => StructAdapter(Type),
        .Optional => |info| OptionalAdapter(info.child),
        .Union => UnionAdapter(Type),
        else => @compileError("unsupported type"),
    };
}

fn ValueAdapter(comptime Type: type) type {
    return struct {
        val: Type,

        fn init(val: Type) @This() {
            return .{ .val = val };
        }

        fn value(self: @This()) !Type {
            return self.val;
        }
    };
}

fn PointerAdapter(comptime Child: type) type {
    return struct {
        val: *const Child,

        fn init(val: *const Child) @This() {
            return .{ .val = val };
        }

        fn value(self: @This()) !Child {
            return self.val.*;
        }
    };
}

fn SliceAdapter(comptime Element: type) type {
    return struct {
        values: []const Element,

        fn init(values: []const Element) @This() {
            return .{ .values = values };
        }

        fn len(self: @This()) !usize {
            return self.values.len;
        }

        fn elem(self: @This(), i: usize) !Adapter(Element) {
            return Adapter(Element).init(self.values[i]);
        }
    };
}

fn ArrayAdapter(comptime Element: type, comptime size: comptime_int) type {
    return struct {
        values: [size]Element,

        fn init(values: [size]Element) @This() {
            return .{ .values = values };
        }

        fn elem(self: @This(), i: usize) !Adapter(Element) {
            return Adapter(Element).init(self.values[i]);
        }
    };
}

fn StructAdapter(comptime Struct: type) type {
    return struct {
        val: Struct,

        const fields = @typeInfo(Struct).Struct.fields;

        fn init(val: Struct) @This() {
            return .{ .val = val };
        }

        fn field(self: @This(), comptime field_index: comptime_int) !Adapter(fields[field_index].type) {
            const f = fields[field_index];
            return Adapter(f.type).init(@field(self.val, f.name));
        }
    };
}

fn OptionalAdapter(comptime Child: type) type {
    return struct {
        child: ?Child,

        fn init(child: ?Child) @This() {
            return .{ .child = child };
        }

        fn value(self: @This()) !?Adapter(Child) {
            if (self.child) |child| {
                return Adapter(Child).init(child);
            }
            return null;
        }
    };
}

fn UnionAdapter(comptime Union: type) type {
    return struct {
        val: Union,

        const Tag = std.meta.Tag(Union);
        fn Payload(comptime t: Tag) type {
            return std.meta.TagPayload(Union, t);
        }

        fn init(val: Union) @This() {
            return .{ .val = val };
        }

        fn tag(self: @This()) !Tag {
            return self.val;
        }

        fn value(self: @This(), comptime t: Tag) !Adapter(Payload(t)) {
            return Adapter(Payload(t)).init(@field(self.val, @tagName(t)));
        }
    };
}
