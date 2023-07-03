const std = @import("std");
const definition = @import("../definition.zig");
const serde = @import("../serde.zig");
const meta = @import("meta.zig");

pub fn ObjectView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime name: []const u8,
) type {
    comptime {
        const info = Index.objInfo(scheme, name);

        var union_fields: [info.versions.len + 1]std.builtin.Type.UnionField = undefined;
        for (info.versions, 0..) |ver_info, i| {
            const VersionField = FieldTypeView(Index, scheme, ver_info);
            union_fields[i] = .{
                .name = meta.verFieldName(i),
                .type = VersionField,
                .alignment = @alignOf(VersionField),
            };
        }
        union_fields[info.versions.len] = .{
            .name = "unknown",
            .type = void,
            .alignment = @alignOf(void),
        };

        return @Type(.{
            .Union = .{
                .layout = .Auto,
                .tag_type = VersionEnum(info.versions.len),
                .fields = &union_fields,
                .decls = &[_]std.builtin.Type.Declaration{},
            },
        });
    }
}

fn VersionEnum(comptime num_versions: comptime_int) type {
    comptime {
        var fields: [num_versions + 1]std.builtin.Type.EnumField = undefined;
        for (0..num_versions) |i| {
            fields[i] = .{
                .name = meta.verFieldName(i),
                .value = i,
            };
        }
        fields[num_versions] = .{
            .name = "unknown",
            .value = num_versions,
        };
        return @Type(.{
            .Enum = .{
                .tag_type = std.math.IntFittingRange(0, num_versions),
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_exhaustive = true,
            },
        });
    }
}

fn FieldTypeView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime info: definition.FieldType,
) type {
    return switch (info) {
        .Void => void,
        .Bool => bool,
        .Int => |int_info| @Type(.{ .Int = int_info }),
        .Float => |float_info| @Type(.{ .Float = float_info }),
        .Optional => |child_info| ?FieldTypeView(Index, scheme, child_info.*),
        .Ref => |ref_info| RefView(
            Index,
            ref_info.scheme orelse scheme,
            ref_info.name,
        ),
        .Array => |array_info| ArrayView(Index, scheme, array_info),
        .List => |child_info| ListView(Index, scheme, child_info.*),
        .Map => |map_info| MapView(Index, scheme, map_info),
        .String => []const u8,
        .Struct => |fields| StructView(Index, scheme, fields),
        .Tuple => |fields| TupleView(Index, scheme, fields),
        .Union => |fields| UnionView(Index, scheme, fields),
        .Enum => |fields| meta.FieldTypeEnum(fields),
    };
}

fn RefView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime name: []const u8,
) type {
    return struct {
        index: *Index,
        id: u64,

        const ViewType = ObjectView(Index, scheme, name);
        const Self = @This();

        pub fn read(self: *const Self) ?ViewType {
            const bytes = self.index.getBytes(scheme, name, self.id);
            if (bytes) |b| {
                return readObject(Index, scheme, name, self.index, b);
            }
            return null;
        }
    };
}

fn ArrayView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime info: definition.FieldType.Array,
) type {
    return struct {
        index: if (fieldTypeNeedsIndex(info.child.*)) *Index else void,
        ends: []align(1) const usize,
        bytes: []const u8,

        const ChildView = FieldTypeView(Index, scheme, info.child.*);
        const Self = @This();

        pub fn read(self: *const Self, idx: usize) ChildView {
            if (info.len == 0) {
                @compileError("cannot read zero element array");
            }

            if (idx >= info.len) {
                @panic("array index out of bounds");
            }

            if (comptime fieldTypeSize(info.child.*)) |child_size| {
                const start = child_size * idx;
                const end = start + child_size;
                return readFieldType(ChildView, info.child.*, self.index, self.bytes[start..end]).value;
            }

            return readChildAt(ChildView, info.child.*, self.index, self.ends, self.bytes, idx);
        }
    };
}

fn ListView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime child_info: definition.FieldType,
) type {
    return struct {
        index: if (fieldTypeNeedsIndex(child_info)) *Index else void,
        len: usize,
        ends: []align(1) const usize,
        bytes: []const u8,

        const ChildView = FieldTypeView(Index, scheme, child_info);
        const Self = @This();

        pub fn read(self: *const Self, idx: usize) ChildView {
            if (idx >= self.len) {
                @panic("list index out of bounds");
            }
            return readChildAt(ChildView, child_info, self.index, self.ends, self.bytes, idx);
        }
    };
}

inline fn readChildAt(
    comptime ChildView: type,
    comptime child_info: definition.FieldType,
    index: anytype,
    ends: []align(1) const usize,
    bytes: []const u8,
    idx: usize,
) ChildView {
    var start: usize = undefined;
    var end: usize = undefined;
    if (comptime fieldTypeSize(child_info)) |child_size| {
        start = child_size * idx;
        end = start + child_size;
    } else {
        start = if (idx == 0) 0 else ends[idx - 1];
        end = ends[idx];
    }
    return readFieldType(ChildView, child_info, index, bytes[start..end]).value;
}

fn MapView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime info: definition.FieldType.Map,
) type {
    return struct {
        index: if (key_needs_index or value_needs_index) *Index else void,
        len: usize,
        ends: []align(1) const usize,
        bytes: []const u8,

        const KeyView = FieldTypeView(Index, scheme, info.key.*);
        const ValueView = FieldTypeView(Index, scheme, info.value.*);
        pub const KeyValue = struct {
            key: KeyView,
            value: ValueView,
        };

        const key_needs_index = fieldTypeNeedsIndex(info.key.*);
        const value_needs_index = fieldTypeNeedsIndex(info.value.*);

        const Self = @This();

        pub fn read(self: *const Self, idx: usize) KeyValue {
            if (idx >= self.len) {
                @panic("map index out of bounds");
            }

            const key_size = comptime fieldTypeSize(info.key.*);
            const value_size = comptime fieldTypeSize(info.value.*);

            var key_start: usize = undefined;
            var key_end: usize = undefined;
            var value_end: usize = undefined;
            if (key_size != null and value_size != null) {
                key_start = (key_size.? + value_size.?) * idx;
                key_end = key_start + key_size.?;
                value_end = key_end + value_size.?;
            } else if (key_size) |ks| {
                key_start = if (idx == 0) 0 else self.ends[idx - 1];
                key_end = key_start + ks;
                value_end = self.ends[idx];
            } else if (value_size) |vs| {
                key_start = if (idx == 0) 0 else (self.ends[idx - 1] + vs);
                key_end = self.ends[idx];
                value_end = key_end + vs;
            } else {
                const end_idx = idx * 2;
                key_start = if (end_idx == 0) 0 else self.ends[end_idx - 1];
                key_end = self.ends[end_idx];
                value_end = self.ends[end_idx + 1];
            }

            const key = readFieldType(
                KeyView,
                info.key.*,
                if (key_needs_index) self.index else @as(void, undefined),
                self.bytes[key_start..key_end],
            ).value;

            const value = readFieldType(
                ValueView,
                info.value.*,
                if (value_needs_index) self.index else @as(void, undefined),
                self.bytes[key_end..value_end],
            ).value;

            return KeyValue{
                .key = key,
                .value = value,
            };
        }
    };
}

fn StructView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime fields: []const definition.FieldType.StructField,
) type {
    comptime {
        var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;
        for (fields, 0..) |field, i| {
            const FieldType = FieldTypeView(Index, scheme, field.type);
            struct_fields[i] = .{
                .name = field.name,
                .type = FieldType,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(FieldType),
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

fn TupleView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime fields: []const definition.FieldType,
) type {
    comptime {
        var field_types: [fields.len]type = undefined;
        for (fields, 0..) |field, i| {
            field_types[i] = FieldTypeView(Index, scheme, field);
        }
        return meta.Tuple(field_types);
    }
}

fn UnionView(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime fields: []const definition.FieldType.UnionField,
) type {
    comptime {
        var enum_fields: [fields.len]std.builtin.Type.EnumField = undefined;
        var union_fields: [fields.len]std.builtin.Type.UnionField = undefined;
        for (fields, 0..) |field, i| {
            enum_fields[i] = .{
                .name = field.name,
                .value = i,
            };

            const FieldType = FieldTypeView(Index, scheme, field.type);
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
}

fn Read(comptime T: type) type {
    return struct {
        value: T,
        bytes: []const u8,
    };
}

pub fn readObject(
    comptime Index: type,
    comptime scheme: []const u8,
    comptime name: []const u8,
    index: *Index,
    bytes: []const u8,
) ObjectView(Index, scheme, name) {
    const View = ObjectView(Index, scheme, name);
    const info = comptime Index.objInfo(scheme, name);

    const read_version = readPacked(u16, bytes);
    const version = read_version.value;
    const read_bytes = read_version.bytes;
    if (version >= info.versions.len) {
        return @unionInit(View, "unknown", undefined);
    }

    const TagIndex = meta.NumEnum(info.versions.len);
    // contains `info.versions.len + 1` fields, hence the need for `TagIndex`.
    const VersionTag = VersionEnum(info.versions.len);
    switch (@as(TagIndex, @enumFromInt(version))) {
        inline else => |tag_idx| {
            // this would index out of bounds if converting a `VerTag`, hence
            // the need for `TagIndex`.
            const field = info.versions[@intFromEnum(tag_idx)];

            // convert the `TagIndex` value to the actual tag value
            const tag: VersionTag = @enumFromInt(@intFromEnum(tag_idx));

            var view = @unionInit(View, @tagName(tag), undefined);
            const FieldType = @TypeOf(@field(view, @tagName(tag)));

            const read_field = readFieldType(
                FieldType,
                field,
                if (comptime fieldTypeNeedsIndex(field)) index else @as(void, undefined),
                read_bytes,
            );
            @field(view, @tagName(tag)) = read_field.value;

            return view;
        },
    }
}

fn readFieldType(
    comptime FieldType: type,
    comptime info: definition.FieldType,
    index: anytype,
    bytes: []const u8,
) Read(FieldType) {
    return switch (info) {
        .Void => {},
        .Bool, .Int, .Float => readPacked(FieldType, bytes),
        .Optional => |child_info| readOptional(FieldType, child_info.*, index, bytes),
        .Ref => readRef(FieldType, index, bytes[0..@sizeOf(u64)]),
        .Array => |array_info| blk: {
            break :blk readArray(FieldType, array_info, index, bytes);
        },
        .List => |child_info| readList(FieldType, child_info.*, index, bytes),
        .Map => |map_info| readMap(FieldType, map_info, index, bytes),
        .String => readString(bytes),
        .Struct => |fields| readStruct(FieldType, fields, index, bytes),
        .Tuple => |fields| readTuple(FieldType, fields, index, bytes),
        .Union => |fields| readUnion(FieldType, fields, index, bytes),
        .Enum => |fields| readEnum(FieldType, fields, bytes),
    };
}

fn readOptional(
    comptime Optional: type,
    comptime child_info: definition.FieldType,
    index: anytype,
    bytes: []const u8,
) Read(Optional) {
    const read_opt = readPacked(u8, bytes);
    switch (read_opt.value) {
        0 => {
            return .{
                .value = null,
                .bytes = read_opt.bytes,
            };
        },
        1 => {
            const Child = @typeInfo(Optional).Optional.child;
            const read_child = readFieldType(
                Child,
                child_info,
                index,
                read_opt.bytes,
            );
            return .{
                .value = read_child.value,
                .bytes = read_child.bytes,
            };
        },
        else => @panic("invalid bytes when reading optional"),
    }
}

fn readRef(
    comptime View: type,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    const read_id = readPacked(u64, bytes);
    return .{
        .value = View{
            .index = index,
            .id = read_id.value,
        },
        .bytes = read_id.bytes,
    };
}

fn readArray(
    comptime View: type,
    comptime info: definition.FieldType.Array,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    if (info.len == 0) {
        return .{
            .value = View{
                .index = index,
                .ends = undefined,
                .bytes = undefined,
            },
            .bytes = bytes,
        };
    }

    var ends: []align(1) const usize = undefined;
    var start: usize = 0;
    var end: usize = 0;
    if (comptime fieldTypeSize(info.child.*)) |child_size| {
        end = info.len * child_size;
    } else {
        ends.ptr = @ptrCast(bytes.ptr);
        ends.len = info.len;

        start = @sizeOf(usize) * info.len;
        end = start + ends[info.len - 1];
    }

    return .{
        .value = View{
            .index = index,
            .ends = ends,
            .bytes = bytes[start..end],
        },
        .bytes = bytes[end..],
    };
}

fn readList(
    comptime View: type,
    comptime child_info: definition.FieldType,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    const read_len = readPacked(usize, bytes);
    const len = read_len.value;
    const read_bytes = read_len.bytes;

    var ends: []align(1) const usize = undefined;
    var start: usize = 0;
    var end: usize = 0;
    if (len > 0) {
        if (comptime fieldTypeSize(child_info)) |child_size| {
            end = child_size * len;
        } else {
            ends.ptr = @ptrCast(read_bytes.ptr);
            ends.len = len;
            start = (@sizeOf(usize) * len);
            end = start + ends[len - 1];
        }
    }

    return .{
        .value = View{
            .index = index,
            .len = len,
            .ends = ends,
            .bytes = read_bytes[start..end],
        },
        .bytes = read_bytes[end..],
    };
}

fn readMap(
    comptime View: type,
    comptime info: definition.FieldType.Map,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    const read_len = readPacked(usize, bytes);
    const len = read_len.value;
    const read_bytes = read_len.bytes;

    var ends: []align(1) const usize = undefined;
    var start: usize = 0;
    var end: usize = 0;
    if (len > 0) {
        const key_size = comptime fieldTypeSize(info.key.*);
        const value_size = comptime fieldTypeSize(info.value.*);

        if (key_size != null and value_size != null) {
            end = (key_size.? + value_size.?) * len;
        } else {
            ends.ptr = @ptrCast(read_bytes.ptr);

            if (key_size != null or value_size != null) {
                ends.len = len;
                start = @sizeOf(usize) * len;
                end = if (key_size != null)
                    ends[len - 1]
                else
                    ends[len - 1] + value_size.?;
            } else {
                ends.len = len * 2;
                start = @sizeOf(usize) * ends.len;
                end = ends[ends.len - 1];
            }
            end += start;
        }
    }

    const key_needs_index = comptime fieldTypeNeedsIndex(info.key.*);
    const value_needs_index = comptime fieldTypeNeedsIndex(info.value.*);
    return .{
        .value = View{
            .index = if (key_needs_index or value_needs_index) index else undefined,
            .len = len,
            .ends = ends,
            .bytes = read_bytes[start..end],
        },
        .bytes = read_bytes[end..],
    };
}

fn readString(bytes: []const u8) Read([]const u8) {
    const read_len = readPacked(usize, bytes);
    const len = read_len.value;
    const read_bytes = read_len.bytes;
    return .{
        .value = read_bytes[0..len],
        .bytes = read_bytes[len..],
    };
}

fn readStruct(
    comptime View: type,
    comptime fields: []const definition.FieldType.StructField,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    var read_bytes = bytes;
    var view: View = undefined;
    inline for (fields) |field| {
        const FieldType = @TypeOf(@field(view, field.name));
        const read_field = readFieldType(
            FieldType,
            field.type,
            if (comptime fieldTypeNeedsIndex(field.type)) index else @as(void, undefined),
            read_bytes,
        );
        @field(view, field.name) = read_field.value;
        read_bytes = read_field.bytes;
    }
    return .{
        .value = view,
        .bytes = read_bytes,
    };
}

fn readTuple(
    comptime View: type,
    comptime fields: []const definition.FieldType,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    var read_bytes = bytes;
    var view: View = undefined;
    inline for (fields, 0..) |field, i| {
        const FieldType = @TypeOf(view[i]);
        const read_field = readFieldType(
            FieldType,
            field,
            if (comptime fieldTypeNeedsIndex(field)) index else @as(void, undefined),
            read_bytes,
        );
        view[i] = read_field.value;
        read_bytes = read_field.bytes;
    }
    return .{
        .value = view,
        .bytes = read_bytes,
    };
}

fn readUnion(
    comptime View: type,
    comptime fields: []const definition.FieldType.UnionField,
    index: anytype,
    bytes: []const u8,
) Read(View) {
    const Tag = std.meta.Tag(View);
    const read_tag = readPacked(usize, bytes);
    const tag_value = read_tag.value;
    const read_bytes = read_tag.bytes;

    if (tag_value >= fields.len) {
        @panic("invalid bytes when reading union tag");
    }

    switch (@as(Tag, @enumFromInt(tag_value))) {
        inline else => |val| {
            const field = fields[@intFromEnum(val)];

            var view = @unionInit(View, field.name, undefined);
            const FieldType = @TypeOf(@field(view, field.name));

            const read_field = readFieldType(
                FieldType,
                field.type,
                if (comptime fieldTypeNeedsIndex(field.type)) index else @as(void, undefined),
                read_bytes,
            );
            @field(view, field.name) = read_field.value;

            return .{
                .value = view,
                .bytes = read_field.bytes,
            };
        },
    }
}

fn readEnum(
    comptime View: type,
    comptime fields: []const definition.FieldType.EnumField,
    bytes: []const u8,
) Read(View) {
    const read_int = readPacked(usize, bytes);

    if (read_int.value >= fields.len) {
        @panic("invalid bytes when reading enum");
    }

    return .{
        .value = @enumFromInt(read_int.value),
        .bytes = read_int.bytes,
    };
}

fn readPacked(comptime Type: type, bytes: []const u8) Read(Type) {
    const value = serde.deserialize(Type, bytes) catch {
        @panic("invalid bytes when reading " ++ @typeName(Type));
    };
    return .{
        .value = value,
        .bytes = bytes[@sizeOf(Type)..],
    };
}

fn fieldTypeSize(comptime info: definition.FieldType) ?usize {
    comptime {
        return switch (info) {
            .Void => 0,
            .Bool => 1,
            .Int => |int_info| @sizeOf(@Type(.{ .Int = int_info })),
            .Float => |float_info| @sizeOf(@Type(.{ .Float = float_info })),
            .Optional => |child_info| if (fieldTypeSize(child_info.*)) |child_size|
                1 + child_size
            else
                null,
            .Ref => @sizeOf(u64),
            .Array => |array_info| if (fieldTypeSize(array_info.child.*)) |child_size|
                child_size * array_info.len
            else
                null,
            .Struct => |fields| fieldsSize(fields),
            .Tuple => |fields| fieldsSize(fields),
            .Union => |fields| blk: {
                var prev_field_size: ?usize = null;
                for (fields) |field| {
                    if (fieldTypeSize(field.type)) |field_size| {
                        if (prev_field_size) |prev_size| {
                            if (field_size != prev_size) {
                                break :blk null;
                            }
                        }
                        prev_field_size = field_size;
                        continue;
                    }

                    break :blk null;
                }
            },
            .Enum => @sizeOf(usize),
            .List, .Map, .String => null,
        };
    }
}

fn fieldsSize(fields: anytype) ?usize {
    comptime {
        var size: usize = 0;
        for (fields) |field| {
            const field_type = if (@hasField(@TypeOf(field), "type"))
                field.type
            else
                field;

            size += fieldTypeSize(field_type) orelse return null;
        }
        return size;
    }
}

fn fieldTypeNeedsIndex(comptime info: definition.FieldType) bool {
    return switch (info) {
        .Void, .Bool, .Int, .Float, .String, .Enum => false,
        .Optional, .List => |child_info| fieldTypeNeedsIndex(child_info.*),
        .Ref => true,
        .Array => |array_info| fieldTypeNeedsIndex(array_info.child.*),
        .Map => |map_info| fieldTypeNeedsIndex(map_info.key.*) or fieldTypeNeedsIndex(map_info.value.*),
        .Struct => |fields| fieldsNeedIndex(fields),
        .Tuple => |fields| fieldsNeedIndex(fields),
        .Union => |fields| fieldsNeedIndex(fields),
    };
}

fn fieldsNeedIndex(fields: anytype) bool {
    for (fields) |field| {
        const field_type = if (@hasField(@TypeOf(field), "type"))
            field.type
        else
            field;

        if (fieldTypeNeedsIndex(field_type)) {
            return true;
        }
    }
    return false;
}

test "bool view" {
    const Index = TestIndex(.{bool});
    var index = Index.init();
    defer index.deinit();

    const expected = true;
    try index.add(0, expected);

    const view = index.read(0);
    try std.testing.expectEqual(expected, view.v1);
}

test "int view" {
    const Index = TestIndex(.{u24});
    var index = Index.init();
    defer index.deinit();

    const expected: u24 = 19810;
    try index.add(0, expected);
    const view = index.read(0);
    try std.testing.expectEqual(expected, view.v1);
}

test "float view" {
    const Index = TestIndex(.{f32});
    var index = Index.init();
    defer index.deinit();

    const expected: f32 = 1908.12;
    try index.add(0, expected);
    const view = index.read(0);
    try std.testing.expectEqual(expected, view.v1);
}

test "optional view with some" {
    const Index = TestIndex(.{?bool});
    var index = Index.init();
    defer index.deinit();

    const expected: ?bool = true;
    try index.add(0, expected);
    const view = index.read(0);
    try std.testing.expectEqual(expected, view.v1);
}

test "optional view with null" {
    const Index = TestIndex(.{?bool});
    var index = Index.init();
    defer index.deinit();

    const expected: ?bool = null;
    try index.add(0, expected);
    const view = index.read(0);
    try std.testing.expectEqual(expected, view.v1);
}

test "ref view" {
    const Index = TestIndex(.{define.This("Obj")});
    var index = Index.init();
    defer index.deinit();

    const ref0 = super.ObjectId{ .scheme = 0, .source = 0, .name = 0 };
    const ref1 = super.ObjectId{ .scheme = 0, .source = 0, .name = 1 };
    try index.add(0, ref1);
    try index.add(0, ref0);

    var view0 = index.read(0);
    var view1 = index.read(1);
    try std.testing.expectEqual(@as(u64, @bitCast(ref1)), view0.v1.id);
    try std.testing.expectEqual(@as(u64, @bitCast(ref0)), view1.v1.id);
}

test "string view" {
    const Index = TestIndex(.{define.String});
    var index = Index.init();
    defer index.deinit();

    const expected: []const u8 = "string";
    try index.add(0, expected);
    const view = index.read(0);
    try std.testing.expectEqualDeep(expected, view.v1);
}

test "array view with sized child" {
    const Index = TestIndex(.{define.Array(2, u8)});
    var index = Index.init();
    defer index.deinit();

    const expected = [_]u8{ 10, 20 };
    try index.add(0, expected);

    const view = index.read(0);
    try std.testing.expectEqual(expected[0], view.v1.read(0));
    try std.testing.expectEqual(expected[1], view.v1.read(1));
}

test "array view with unsized child" {
    const Index = TestIndex(.{define.Array(2, define.String)});
    var index = Index.init();
    defer index.deinit();

    const expected = [_][]const u8{ "Hello", "world" };
    try index.add(0, expected);

    const view = index.read(0);
    try std.testing.expectEqualDeep(expected[0], view.v1.read(0));
    try std.testing.expectEqualDeep(expected[1], view.v1.read(1));
}

test "list view with sized child" {
    const Index = TestIndex(.{define.List(u8)});
    var index = Index.init();
    defer index.deinit();

    const expected = [_]u8{ 10, 20 };
    try index.add(0, expected);

    const view = index.read(0);
    try std.testing.expectEqual(expected[0], view.v1.read(0));
    try std.testing.expectEqual(expected[1], view.v1.read(1));
}

test "list view with unsized child" {
    const Index = TestIndex(.{define.List(define.String)});
    var index = Index.init();
    defer index.deinit();

    const expected = [_][]const u8{ "Hello", "world", "!" };
    try index.add(0, expected);

    const view = index.read(0);
    try std.testing.expectEqualDeep(expected[0], view.v1.read(0));
    try std.testing.expectEqualDeep(expected[1], view.v1.read(1));
    try std.testing.expectEqualDeep(expected[2], view.v1.read(2));
}

test "map view with sized key and value" {
    const Index = TestIndex(.{define.Map(u8, u8)});
    var index = Index.init();
    defer index.deinit();

    const expected = [_]struct { u8, u8 }{ .{ 10, 20 }, .{ 30, 40 } };
    try index.add(0, expected);

    const view = index.read(0);
    try std.testing.expectEqual(expected[0][0], view.v1.read(0).key);
    try std.testing.expectEqual(expected[0][1], view.v1.read(0).value);
    try std.testing.expectEqual(expected[1][0], view.v1.read(1).key);
    try std.testing.expectEqual(expected[1][1], view.v1.read(1).value);
}

test "map view with sized key" {
    const Index = TestIndex(.{define.Map(u8, define.String)});
    var index = Index.init();
    defer index.deinit();

    const expected = [_]struct { u8, []const u8 }{ .{ 10, "Hello" }, .{ 30, "world" } };
    try index.add(0, expected);

    const view = index.read(0);
    try std.testing.expectEqual(expected[0][0], view.v1.read(0).key);
    try std.testing.expectEqualDeep(expected[0][1], view.v1.read(0).value);
    try std.testing.expectEqual(expected[1][0], view.v1.read(1).key);
    try std.testing.expectEqualDeep(expected[1][1], view.v1.read(1).value);
}

test "map view with sized value" {
    const Index = TestIndex(.{define.Map(define.String, u8)});
    var index = Index.init();
    defer index.deinit();

    const expected = [_]struct { []const u8, u8 }{ .{ "Hello", 10 }, .{ "world", 30 } };
    try index.add(0, expected);

    const view = index.read(0);
    try std.testing.expectEqualDeep(expected[0][0], view.v1.read(0).key);
    try std.testing.expectEqual(expected[0][1], view.v1.read(0).value);
    try std.testing.expectEqualDeep(expected[1][0], view.v1.read(1).key);
    try std.testing.expectEqual(expected[1][1], view.v1.read(1).value);
}

test "map view unsized key and value" {
    const Index = TestIndex(.{define.Map(define.String, define.String)});
    var index = Index.init();
    defer index.deinit();

    const expected = [_]struct { []const u8, []const u8 }{ .{ "Hello", "cruel" }, .{ "world", "!" } };
    try index.add(0, expected);

    const view = index.read(0);
    try std.testing.expectEqualDeep(expected[0][0], view.v1.read(0).key);
    try std.testing.expectEqualDeep(expected[0][1], view.v1.read(0).value);
    try std.testing.expectEqualDeep(expected[1][0], view.v1.read(1).key);
    try std.testing.expectEqualDeep(expected[1][1], view.v1.read(1).value);
}

test "struct view" {
    const Struct = struct {
        int: u8,
        str: define.String,
        ref: define.This("Obj"),
    };
    const Index = TestIndex(.{Struct});
    var index = Index.init();
    defer index.deinit();

    const expected = .{
        .int = @as(u8, 10),
        .str = @as([]const u8, "string"),
        .ref = super.ObjectId{ .scheme = 0, .source = 0, .name = 0 },
    };
    try index.add(0, expected);

    const view = index.read(0);
    try std.testing.expectEqual(expected.int, view.v1.int);
    try std.testing.expectEqualDeep(expected.str, view.v1.str);
    try std.testing.expectEqual(@as(u64, @bitCast(expected.ref)), view.v1.ref.id);
}

test "tuple view" {
    const Tuple = struct {
        u8,
        define.String,
        define.This("Obj"),
    };
    const Index = TestIndex(.{Tuple});
    var index = Index.init();
    defer index.deinit();

    const expected = .{
        @as(u8, 10),
        @as([]const u8, "string"),
        super.ObjectId{ .scheme = 0, .source = 0, .name = 0 },
    };
    try index.add(0, expected);

    const view = index.read(0);
    try std.testing.expectEqual(expected[0], view.v1[0]);
    try std.testing.expectEqualDeep(expected[1], view.v1[1]);
    try std.testing.expectEqual(@as(u64, @bitCast(expected[2])), view.v1[2].id);
}

test "union view" {
    const Union = union(enum) {
        Int: u8,
        Str: define.String,
        Ref: define.This("Obj"),
    };
    const Index = TestIndex(.{Union});
    var index = Index.init();
    defer index.deinit();

    const Expected = union(enum) {
        Int: u8,
        Str: []const u8,
        Ref: super.ObjectId,
    };

    var expected = Expected{
        .Int = 10,
    };
    try index.add(0, expected);

    var view = index.read(0);
    try std.testing.expectEqualDeep(@tagName(expected), @tagName(view.v1));
    try std.testing.expectEqual(expected.Int, view.v1.Int);

    expected = Expected{
        .Str = "string",
    };
    try index.add(0, expected);
    view = index.read(1);
    try std.testing.expectEqualDeep(@tagName(expected), @tagName(view.v1));
    try std.testing.expectEqualDeep(expected.Str, view.v1.Str);

    expected = Expected{
        .Ref = @bitCast(@as(u64, 0)),
    };
    try index.add(0, expected);
    view = index.read(2);
    try std.testing.expectEqualDeep(@tagName(expected), @tagName(view.v1));
    try std.testing.expectEqualDeep(@as(u64, @bitCast(expected.Ref)), view.v1.Ref.id);
}

test "enum view" {
    const Enum = enum {
        zero,
        one,
        two,
    };
    const Index = TestIndex(.{Enum});
    var index = Index.init();
    defer index.deinit();

    const expected = Enum.one;
    try index.add(0, expected);

    const view = index.read(0);
    try std.testing.expectEqualDeep(@as([]const u8, @tagName(Enum.one)), @tagName(view.v1));
}

test "multiple versions" {
    const Index = TestIndex(.{ u8, u16 });
    var index = Index.init();
    defer index.deinit();

    const exp_ver1: u8 = 10;
    try index.add(0, exp_ver1);

    var view = index.read(0);
    try std.testing.expectEqual(@as(u8, 10), view.v1);

    const exp_ver2: u16 = 20;
    try index.add(1, exp_ver2);
    view = index.read(1);
    try std.testing.expectEqual(@as(u16, 20), view.v2);

    try index.addUnknown();
    view = index.read(2);
    try std.testing.expect(view == .unknown);
}

const define = @import("../define.zig");
const super = @import("../object.zig");
const SharedMem = @import("../SharedMem.zig");

fn TestIndex(comptime types: anytype) type {
    return struct {
        obs: ObjectBytes,

        const ObjectBytes = std.ArrayList([]const u8);
        const Scheme = define.Scheme("test", .{
            define.Object("Obj", types),
        });
        const info = definition.ObjectScheme.from(Scheme(define.This));
        const Self = @This();

        fn init() Self {
            return Self{
                .obs = ObjectBytes.init(std.testing.allocator),
            };
        }

        fn add(self: *Self, comptime version: u16, value: anytype) !void {
            var bytes = std.ArrayList(u8).init(std.testing.allocator);
            try serde.serialize(version, bytes.writer());
            _ = try writeFieldType(definition.FieldType.from(types[version]).?, value, bytes.writer());
            try self.obs.append(try bytes.toOwnedSlice());
        }

        fn addUnknown(self: *Self) !void {
            var bytes = std.ArrayList(u8).init(std.testing.allocator);
            try serde.serialize(@as(u16, types.len), bytes.writer());
            try self.obs.append(try bytes.toOwnedSlice());
        }

        fn deinit(self: *Self) void {
            for (self.obs.items) |bytes| {
                std.testing.allocator.free(bytes);
            }
            self.obs.deinit();
        }

        fn objInfo(comptime _: []const u8, _: []const u8) definition.ObjectScheme.Object {
            return info.objects[0];
        }

        fn read(self: *Self, idx: usize) ObjectView(Self, "test", "Obj") {
            return readObject(Self, "test", "Obj", self, self.obs.items[idx]);
        }

        fn getBytes(self: *Self, comptime _: []const u8, comptime _: []const u8, id: u64) ?[]const u8 {
            const obj_id: super.ObjectId = @bitCast(id);
            return self.obs.items[obj_id.name];
        }
    };
}

fn writeFieldType(comptime info: definition.FieldType, value: anytype, writer: anytype) !usize {
    switch (info) {
        .Void => return 0,
        .Bool, .Int, .Float => {
            try serde.serialize(value, writer);
            return @sizeOf(@TypeOf(value));
        },
        .Optional => |child_info| {
            var child_size: usize = 0;
            if (value) |v| {
                try writer.writeByte(1);
                child_size = try writeFieldType(child_info.*, v, writer);
            } else {
                try writer.writeByte(0);
            }
            return 1 + child_size;
        },
        .Ref => {
            try serde.serialize(@as(u64, @bitCast(value)), writer);
            return @sizeOf(u64);
        },
        .Array => |array_info| {
            if (comptime fieldTypeSize(array_info.child.*)) |child_size| {
                for (value) |v| {
                    _ = try writeFieldType(array_info.child.*, v, writer);
                }
                return child_size * array_info.len;
            } else {
                var ends: [array_info.len]usize = undefined;
                var data = std.ArrayList(u8).init(std.testing.allocator);
                defer data.deinit();

                var size: usize = 0;
                for (value, 0..) |v, i| {
                    size += try writeFieldType(array_info.child.*, v, data.writer());
                    ends[i] = size;
                }

                size += try writeSlice(usize, &ends, writer);
                try writer.writeAll(data.items);

                return size;
            }
        },
        .List => |child_info| {
            try serde.serialize(value.len, writer);
            var size: usize = @sizeOf(usize);
            if (comptime fieldTypeSize(child_info.*)) |child_size| {
                for (value) |v| {
                    _ = try writeFieldType(child_info.*, v, writer);
                }
                size += child_size * value.len;
            } else {
                var ends = try std.ArrayList(usize).initCapacity(std.testing.allocator, value.len);
                defer ends.deinit();

                var data = std.ArrayList(u8).init(std.testing.allocator);
                defer data.deinit();

                var data_size: usize = 0;
                for (value) |v| {
                    data_size += try writeFieldType(child_info.*, v, data.writer());
                    try ends.append(data_size);
                }

                size += try writeSlice(usize, ends.items, writer);
                try writer.writeAll(data.items);
                size += data_size;
            }
            return size;
        },
        .Map => |map_info| {
            try serde.serialize(value.len, writer);
            var size: usize = @sizeOf(usize);

            const key_size = comptime fieldTypeSize(map_info.key.*);
            const value_size = comptime fieldTypeSize(map_info.value.*);

            if (key_size != null and value_size != null) {
                for (value) |v| {
                    _ = try writeFieldType(map_info.key.*, v[0], writer);
                    _ = try writeFieldType(map_info.value.*, v[1], writer);
                }
                size += key_size.? * value.len;
                size += value_size.? * value.len;
            } else {
                var ends = try std.ArrayList(usize).initCapacity(
                    std.testing.allocator,
                    value.len * if (key_size != null or value_size != null) 1 else 2,
                );
                defer ends.deinit();

                const initial_capacity = if (key_size) |ks|
                    ks * value.len
                else if (value_size) |vs|
                    vs * value.len
                else
                    0;

                var data = try std.ArrayList(u8).initCapacity(
                    std.testing.allocator,
                    initial_capacity,
                );
                defer data.deinit();

                var data_size: usize = 0;
                for (value) |v| {
                    data_size += try writeFieldType(map_info.key.*, v[0], data.writer());
                    if (key_size == null) {
                        try ends.append(data_size);
                    }

                    data_size += try writeFieldType(map_info.value.*, v[1], data.writer());
                    if (value_size == null) {
                        try ends.append(data_size);
                    }
                }

                size += try writeSlice(usize, ends.items, writer);
                try writer.writeAll(data.items);
                size += data_size;
            }

            return size;
        },
        .String => {
            try serde.serialize(value.len, writer);
            var size: usize = @sizeOf(usize);
            try writer.writeAll(value);
            size += value.len;
            return size;
        },
        .Struct => |fields| {
            var size: usize = 0;
            inline for (fields) |field| {
                size += try writeFieldType(field.type, @field(value, field.name), writer);
            }
            return size;
        },
        .Tuple => |fields| {
            var size: usize = 0;
            inline for (fields, 0..) |field, i| {
                size += try writeFieldType(field, value[i], writer);
            }
            return size;
        },
        .Union => |fields| {
            switch (value) {
                inline else => |val, tag| {
                    const field = fields[@intFromEnum(tag)];
                    try serde.serialize(@as(usize, @intFromEnum(tag)), writer);
                    var size: usize = @sizeOf(usize);
                    size += try writeFieldType(field.type, val, writer);
                    return size;
                },
            }
        },
        .Enum => {
            try serde.serialize(@as(usize, @intFromEnum(value)), writer);
            return @sizeOf(usize);
        },
    }
}

fn writeSlice(comptime Child: type, slice: []const Child, writer: anytype) !usize {
    var bytes: []const u8 = undefined;
    bytes.ptr = @ptrCast(@alignCast(slice.ptr));
    bytes.len = @sizeOf(Child) * slice.len;
    try writer.writeAll(bytes);
    return bytes.len;
}
