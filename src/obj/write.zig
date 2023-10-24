const std = @import("std");
const def = @import("../lib.zig").def;
const meta = @import("../meta.zig");

pub fn WriteObject(comptime object: def.ObjectScheme.Object) type {
    return struct {
        allocator: std.mem.Allocator,
        value: ?Value,

        const Value = union(enum) {
            New: WriteNewObject(object),
            Mutate: WriteMutateObject(object),
        };
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .value = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn new(self: *Self) *WriteNewObject(object) {
            switch (self.value) {
                .New => {
                    return &self.value.New;
                },
                .Mutate => {},
            }
        }

        pub fn mutate(self: *Self) *WriteMutateObject(object) {
            switch (self.value) {
                .New => {},
                .Mutate => {
                    return &self.value.Mutate;
                },
            }
        }
    };
}

pub fn WriteNewObject(comptime object: def.ObjectScheme.Object) type {
    return struct {
        allocator: Allocator,
        version: ?Version,

        pub const Version = blk: {
            var tag_fields: [object.versions.len]std.builtin.Type.EnumField = undefined;
            var union_fields: [tag_fields.len]std.builtin.Type.UnionField = undefined;
            for (0..tag_fields.len) |i| {
                tag_fields[i] = .{
                    .name = "V" ++ meta.numFieldName(i),
                    .value = i,
                };

                const Type = WriteNewType(object.versions[i]);
                union_fields[i] = .{
                    .name = tag_fields[i].name,
                    .type = Type,
                    .alignment = @alignOf(Type),
                };
            }
            break :blk @Type(.{
                .Union = .{
                    .layout = .Auto,
                    .tag_type = @Type(.{
                        .Enum = .{
                            .tag_type = std.math.IntFittingRange(0, tag_fields - 1),
                            .fields = &tag_fields,
                            .decls = &[_]std.builtin.Type.Declaration{},
                            .is_exhaustive = true,
                        },
                    }),
                    .fields = &union_fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                },
            });
        };
        const Allocator = if (newObjectAllocates(object)) std.mem.Allocator else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .version = null,
            };
        }

        pub fn version(self: *Self, comptime num: comptime_int) *WriteNewType(object.versions[num]) {
            const field_name = "V" ++ meta.numFieldName(num);
            const field_type = object.versions[num];
            switch (self.version) {
                .None => {},
                inline else => |val, tag| {
                    if (@intFromEnum(tag) == num) {
                        return &@field(self.version, field_name);
                    }
                    if (comptime newTypeAllocates(field_type)) {
                        deinitNewType(self.allocator, field_type, val);
                    }
                },
            }

            const FieldType = WriteNewType(field_type);
            if (comptime newTypeTakesAllocator(field_type)) {
                self.version = @unionInit(
                    Version,
                    field_name,
                    if (comptime newTypeAllocates(object.versions[num]))
                        FieldType.init(self.allocator)
                    else
                        FieldType.init(undefined),
                );
            } else {
                self.version = @unionInit(Version, field_name, FieldType.init());
            }

            return &@field(self.version, field_name);
        }
    };
}

pub fn WriteNewType(comptime typ: def.Type) type {
    return switch (typ) {
        .Void => WriteVoid,
        .Bool => WriteBool,
        .String => WriteNewString,
        .Int => |info| WriteInt(info),
        .Float => |info| WriteFloat(info),
        .Optional => |info| WriteNewOptional(info),
        .Array => |info| WriteNewArray(info),
        .List => |info| WriteNewList(info),
        .Map => |info| WriteNewMap(info),
        .Struct => |info| WriteNewStruct(info),
        .Tuple => |info| WriteNewTuple(info),
        .Union => |info| WriteNewUnion(info),
        .Enum => |info| WriteEnum(info),
        .Ref => WriteRef,
    };
}

pub const WriteNewString = struct {
    allocator: std.mem.Allocator,
    str: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) WriteNewString {
        return WriteNewString{
            .allocator = allocator,
            .str = null,
        };
    }

    pub fn set(self: *WriteNewString, str: []const u8) !void {
        if (self.str) |old_str| {
            self.allocator.free(old_str);
        }
        self.str = try self.allocator.dupe(u8, str);
    }
};

pub fn WriteNewOptional(comptime info: def.Type.Optional) type {
    return struct {
        allocator: Allocator,
        opt: Option,

        pub const Option = union(enum) {
            Some: ?WriteNewType(info.child.*),
            None,
        };
        pub const FieldType = WriteNewType(info.chid.*);
        const Allocator = if (newTypeAllocates(info.child.*)) std.mem.Allocator else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .value = .None,
            };
        }

        pub fn some(self: *Self) *FieldType {
            if (self.opt == .None or self.opt.Some == null) {
                if (comptime newTypeTakesAllocator(info.child.*)) {
                    self.opt = Option{
                        .Some = if (comptime newTypeAllocates(info.child.*))
                            FieldType.init(self.allocator)
                        else
                            FieldType.init(undefined),
                    };
                } else {
                    self.opt = Option{
                        .Some = FieldType.init(),
                    };
                }
            }
            return &self.opt.Some.?;
        }

        pub fn none(self: *Self) void {
            if (self.opt == .None) {
                self.opt = Option{
                    .Some = null,
                };
            }
        }
    };
}

pub fn WriteNewArray(comptime info: def.Type.Array) type {
    return struct {
        allocator: Allocator,
        elems: [info.len]?Element,

        pub const Element = WriteNewType(info.child.*);
        const Allocator = if (newTypeAllocates(info.child.*)) std.mem.Allocator else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .elems = [_]?Element{null} ** info.len,
            };
        }

        pub fn elem(self: *Self, at: usize) *Element {
            if (at >= info.len) {
                @panic("index out of bounds");
            }

            if (self.elems[at] == null) {
                if (comptime newTypeTakesAllocator(info.child.*)) {
                    if (comptime newTypeAllocates(info.child.*)) {
                        self.elems[at] = Element.init(self.allocator);
                    } else {
                        self.elems[at] = Element.init(undefined);
                    }
                } else {
                    self.elems[at] = Element.init();
                }
            }

            return &self.elems[at].?;
        }
    };
}

pub fn WriteNewList(comptime info: def.Type.List) type {
    return struct {
        elems: std.ArrayList(Element),

        pub const Element = WriteNewType(info.child.*);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .elems = std.ArrayList(Element).init(allocator) };
        }

        pub fn append(self: *Self) !*Element {
            if (comptime newTypeTakesAllocator(info.child.*)) {
                if (comptime newTypeAllocates(info.child.*)) {
                    try self.elems.append(Element.init(self.list.allocator));
                } else {
                    try self.elems.append(Element.init(undefined));
                }
            } else {
                try self.elems.append(Element.init());
            }
            return &self.elems.items[self.len() - 1];
        }

        pub fn elem(self: *Self, at: usize) *Element {
            if (at >= self.elems.items.len) {
                @panic("index out of bounds");
            }

            return &self.elems.items[at];
        }

        pub fn len(self: *const Self) usize {
            return self.elems.items.len;
        }
    };
}

pub fn WriteNewMap(comptime info: def.Type.Map) type {
    return struct {
        entries: std.ArrayList(Entry),

        pub const Entry = WriteNewMapEntry(info);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .entries = std.ArrayList(Entry).init(allocator) };
        }

        pub fn put(self: *Self) !*Entry {
            if (comptime newTypeAllocates(info.key.*) or newTypeAllocates(info.value.*)) {
                try self.entries.append(Entry.init(self.entries.allocator));
            } else {
                try self.entries.append(Entry.init(undefined));
            }
            return &self.entries.items[self.len() - 1];
        }

        pub fn entry(self: *Self, at: usize) *Entry {
            if (at >= self.entries.items.len) {
                @panic("index out of bounds");
            }

            return &self.entries.items[at];
        }

        pub fn len(self: *Self) usize {
            return self.entries.items.len;
        }
    };
}

pub fn WriteNewMapEntry(comptime info: def.Type.Map) type {
    return struct {
        allocator: Alloc,
        key: ?Key,
        value: ?Value,

        pub const Key = WriteNewType(info.key.*);
        pub const Value = WriteNewType(info.value.*);
        const Alloc = if (newTypeAllocates(info.key.*) or newTypeAllocates(info.value.*)) std.mem.Allocator else void;
        const Self = @This();

        pub fn init(allocator: Alloc) Self {
            return Self{
                .allocator = allocator,
                .key = null,
                .value = null,
            };
        }

        pub fn key(self: *Self) *Key {
            if (self.key == null) {
                if (comptime newTypeTakesAllocator(info.key.*)) {
                    if (comptime newTypeAllocates(info.key.*)) {
                        self.key = Key.init(self.allocator);
                    } else {
                        self.key = Key.init(undefined);
                    }
                } else {
                    self.key = Key.init();
                }
            }
            return &self.key.?;
        }

        pub fn value(self: *Self) *Value {
            if (self.value == null) {
                if (comptime newTypeTakesAllocator(info.value.*)) {
                    if (comptime newTypeAllocates(info.value.*)) {
                        self.value = Value.init(self.allocator);
                    } else {
                        self.value = Value.init(undefined);
                    }
                } else {
                    self.value = Value.init();
                }
            }
            return &self.value.?;
        }
    };
}

pub fn WriteNewStruct(comptime info: def.Type.Struct) type {
    return struct {
        allocator: Alloc,
        fields: Fields,

        pub const Fields = blk: {
            var fields: [info.fields.len]std.builtin.Type.Struct = undefined;
            for (info.fields, 0..) |f, i| {
                const Type = ?WriteNewType(f.type);
                fields[i] = .{
                    .name = f.name,
                    .type = Type,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(Type),
                };
            }
            break :blk @Type(.{
                .Struct = .{
                    .layout = .Auto,
                    .backing_integer = null,
                    .fields = &fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_tuple = false,
                },
            });
        };

        pub fn FieldType(comptime name: std.meta.FieldEnum(Fields)) type {
            const OptType = std.meta.FieldType(Fields, name);
            return std.meta.Child(OptType);
        }

        const Alloc = for (info.fields) |f| {
            if (newTypeAllocates(f.type)) break std.mem.Allocator;
        } else void;
        const Self = @This();

        pub fn init(allocator: Alloc) Self {
            var fields: Fields = undefined;
            inline for (info.fields) |f| {
                @field(fields, f.name) = null;
            }
            return Self{
                .allocator = allocator,
                .fields = fields,
            };
        }

        pub fn field(self: *Self, comptime name: std.meta.FieldEnum(Fields)) *FieldType(name) {
            const field_type = info.fields[@intFromEnum(name)].type;
            const field_name = @tagName(name);
            if (@field(self.fields, field_name) == null) {
                if (comptime newTypeTakesAllocator(field_type)) {
                    if (comptime newTypeAllocates(field_type)) {
                        @field(self.fields, field_name) = FieldType(name).init(self.allocator);
                    } else {
                        @field(self.fields, field_name) = FieldType(name).init(undefined);
                    }
                } else {
                    @field(self.fields, field_name) = FieldType(name).init();
                }
            }
            return &@field(self.fields, field_name).?;
        }
    };
}

pub fn WriteNewTuple(comptime info: def.Type.Tuple) type {
    return struct {
        allocator: Alloc,
        fields: Fields,

        pub const Fields = blk: {
            var fields: [info.fields.len]std.builtin.Type.Struct = undefined;
            for (info.fields, 0..) |f, i| {
                const Type = ?WriteNewType(f);
                fields[i] = .{
                    .name = meta.numFieldName(i),
                    .type = Type,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(Type),
                };
            }
            break :blk @Type(.{
                .Struct = .{
                    .layout = .Auto,
                    .backing_integer = null,
                    .fields = &fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_tuple = true,
                },
            });
        };

        pub fn FieldType(comptime index: comptime_int) type {
            const OptType = std.meta.fields(Fields)[index].type;
            return std.meta.Child(OptType);
        }

        const Alloc = for (info.fields) |f| {
            if (newTypeAllocates(f)) break std.mem.Allocator;
        } else void;
        const Self = @This();

        pub fn init(allocator: Alloc) Self {
            var fields: Fields = undefined;
            inline for (0..info.fields.len) |i| {
                fields[i] = null;
            }
            return Self{
                .allocator = allocator,
                .fields = fields,
            };
        }

        pub fn field(self: *Self, comptime index: comptime_int) *FieldType(index) {
            const field_type = info.fields[index];
            if (self.fields[index] == null) {
                if (comptime newTypeTakesAllocator(field_type)) {
                    if (comptime newTypeAllocates(field_type)) {
                        self.fields[index] = FieldType(index).init(self.allocator);
                    } else {
                        self.fields[index] = FieldType(index).init(undefined);
                    }
                } else {
                    self.fields[index] = FieldType(index).init();
                }
            }
            return &self.fields[index].?;
        }
    };
}

pub fn WriteNewUnion(comptime info: def.Type.Union) type {
    return struct {
        allocator: Allocator,
        active: ?Fields,

        pub const Fields = blk: {
            var tag_fields: [info.fields.len]std.builtin.Type.EnumField = undefined;
            var fields: [info.fields.len]std.builtin.Type.UnionField = undefined;
            for (info.fields, 0..) |f, i| {
                tag_fields[i] = .{
                    .name = f.name,
                    .active = i,
                };

                const Type = WriteNewType(f.type);
                fields[i] = .{
                    .name = f.name,
                    .type = Type,
                    .alignment = @alignOf(Type),
                };
            }
            break :blk @Type(.{
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
        };

        pub fn FieldType(comptime name: std.meta.FieldEnum(Fields)) type {
            return std.meta.FieldType(Fields, name);
        }

        const Allocator = for (info.fields) |f| {
            if (newTypeAllocates(f.type)) break std.mem.Allocator;
        } else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .fields = null,
            };
        }

        pub fn field(self: *Self, comptime name: std.meta.FieldEnum(Fields)) *FieldType(name) {
            const field_name = @tagName(name);
            const field_type = info.fields[@intFromEnum(name)].type;
            if (self.active) |*active| {
                switch (active) {
                    inline else => |*val, tag| {
                        if (@intFromEnum(tag) == @intFromEnum(name)) {
                            return val;
                        }

                        if (comptime newTypeAllocates(field_type)) {
                            deinitNewType(self.allocator, field_type, val);
                        }
                    },
                }
            }

            if (comptime newTypeTakesAllocator(field_type)) {
                if (comptime newTypeAllocates(field_type)) {
                    self.active = @unionInit(Fields, field_name, FieldType(name).init(self.allocator));
                } else {
                    self.active = @unionInit(Fields, field_name, FieldType(name).init(undefined));
                }
            } else {
                self.active = @unionInit(Fields, field_name, FieldType(name).init());
            }

            return &@field(self.active.?, field_name);
        }
    };
}

pub fn WriteMutateObject(comptime object: def.ObjectScheme.Object) type {
    _ = object;
}

pub const WriteVoid = struct {
    pub fn init() WriteVoid {
        return WriteVoid{};
    }
};

pub const WriteBool = struct {
    value: ?bool,

    pub fn init() WriteBool {
        return WriteBool{ .value = null };
    }

    pub fn set(self: *WriteBool, value: bool) void {
        self.value = value;
    }
};

pub fn WriteInt(comptime info: def.Type.Int) type {
    return struct {
        value: ?Int,

        pub const Int = @Type(.{
            .Int = .{
                .signedness = switch (info.signedness) {
                    .signed => .signed,
                    .unsigned => .unsigned,
                },
                .bits = info.bits,
            },
        });
        const Self = @This();

        pub fn init() Self {
            return Self{ .value = null };
        }

        pub fn set(self: *Self, value: Int) void {
            self.value = value;
        }
    };
}

pub fn WriteFloat(comptime info: def.Type.Float) type {
    return struct {
        value: ?Float,

        pub const Float = @Type(.{
            .Float = .{
                .bits = info.bits,
            },
        });
        const Self = @This();

        pub fn init() Self {
            return Self{ .value = null };
        }

        pub fn set(self: *Self, value: Float) void {
            self.value = value;
        }
    };
}

pub fn WriteEnum(comptime info: def.Type.Enum) type {
    return struct {
        value: ?Enum,

        pub const Enum = blk: {
            var fields: [info.fields.len]std.builtin.Type.Enum = undefined;
            for (info.fields, 0..) |field, i| {
                fields[i] = .{
                    .name = field.name,
                    .value = i,
                };
            }
            break :blk @Type(.{
                .Enum = .{
                    .tag_type = std.math.IntFittingRange(0, info.fields.len),
                    .fields = &fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_exhaustive = true,
                },
            });
        };
        const Self = @This();

        pub fn init() Self {
            return Self{ .value = null };
        }

        pub fn set(self: *Self, value: Enum) void {
            self.value = value;
        }
    };
}

pub const WriteRef = struct {
    value: ?def.ObjectId,

    pub fn init() WriteRef {
        return WriteRef{ .value = null };
    }

    pub fn set(self: *WriteRef, value: def.ObjectId) void {
        self.value = value;
    }
};

fn deinitNewObject(
    allocator: std.mem.Allocator,
    comptime object: def.ObjectScheme.Object,
    value: *WriteNewObject(object),
) void {
    switch (value) {
        inline else => |*val, tag| {
            const ver_type = object.versions[@intFromEnum(tag)];
            if (comptime newTypeAllocates(ver_type)) {
                deinitNewType(allocator, ver_type, val);
            }
        },
    }
}

fn deinitNewType(allocator: std.mem.Allocator, comptime typ: def.Type, value: *WriteNewType(type)) void {
    switch (typ) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => {},
        .String => {
            if (value.str) |str| {
                allocator.free(str);
            }
        },
        .Optional => |info| {
            if (value.opt) |*opt| {
                if (comptime newTypeAllocates(info.child.*)) {
                    deinitNewType(allocator, info.child.*, opt);
                }
            }
        },
        .Array => |info| {
            if (comptime newTypeAllocates(info.child.*)) {
                for (value) |*elem| {
                    if (elem) |*e| {
                        deinitNewType(allocator, info.child.*, e);
                    }
                }
            }
        },
        .List => |info| {
            if (comptime newTypeAllocates(info.child.*)) {
                for (value.elems.items) |*elem| {
                    deinitNewType(allocator, info.child.*, elem);
                }
            }
            value.elems.deinit();
        },
        .Map => |info| {
            if (comptime newTypeAllocates(info.key.*) or newTypeAllocates(info.value.*)) {
                for (value.entries.items) |*entry| {
                    if (comptime newTypeAllocates(info.key.*)) {
                        if (entry.key) |*key| {
                            deinitNewType(allocator, info.key.*, key);
                        }
                    }

                    if (comptime newTypeAllocates(info.value.*)) {
                        if (entry.value) |*val| {
                            deinitNewType(allocator, info.value.*, val);
                        }
                    }
                }
            }
            value.entries.deinit();
        },
        .Struct => |info| {
            inline for (info.fields) |field| {
                if (comptime newTypeAllocates(field.type)) {
                    if (@field(value, field.name)) |*val| {
                        deinitNewType(allocator, field.type, val);
                    }
                }
            }
        },
        .Tuple => |info| {
            inline for (info.fields, 0..) |f, i| {
                if (comptime newTypeAllocates(f)) {
                    if (value[i]) |*val| {
                        deinitNewType(allocator, f, val);
                    }
                }
            }
        },
        .Union => |info| {
            if (value.active) |*active| {
                switch (active) {
                    inline else => |*val, tag| {
                        const field_type = info.fields[@intFromEnum(tag)].type;
                        if (comptime newTypeAllocates(field_type)) {
                            deinitNewType(allocator, field_type, val);
                        }
                    },
                }
            }
        },
    }
}

fn newObjectAllocates(comptime object: def.ObjectScheme.Object) bool {
    return for (object.versions) |ver| {
        if (comptime newTypeAllocates(ver)) break true;
    } else false;
}

fn newTypeAllocates(comptime typ: def.Type) bool {
    return switch (typ) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => false,
        .String, .List, .Map => true,
        .Optional => |info| comptime newTypeAllocates(info.child.*),
        .Array => |info| comptime newTypeAllocates(info.child.*),
        .Struct => |info| for (info.fields) |field| {
            if (comptime newTypeAllocates(field.type)) break true;
        } else false,
        .Tuple => |info| for (info.fields) |field| {
            if (comptime newTypeAllocates(field)) break true;
        } else false,
        .Union => |info| for (info.fields) |field| {
            if (comptime newTypeAllocates(field.type)) break true;
        } else false,
    };
}

fn newTypeTakesAllocator(comptime typ: def.Type) bool {
    return switch (typ) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => false,
        else => true,
    };
}
