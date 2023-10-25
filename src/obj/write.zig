const std = @import("std");
const def = @import("../lib.zig").def;
const meta = @import("../meta.zig");
const serde = @import("serde.zig");

pub fn WriteObject(comptime object: def.ObjectScheme.Object) type {
    return struct {
        allocator: std.mem.Allocator,
        object: ?Object,

        pub const Object = union(enum) {
            New: New,
            Mutate: Mutate,
        };
        pub const New = WriteNewObject(object);
        pub const Mutate = WriteMutateObject(object);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .value = null,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.object) |*obj| {
                switch (obj) {
                    .New => |*n| deinitNewObject(n),
                    .Mutate => |*m| deinitMutateObject(m),
                }
            }
        }

        pub fn new(self: *Self) *New {
            if (self.object) |*obj| {
                switch (obj) {
                    .New => |*n| return n,
                    .Mutate => |*m| deinitMutateObject(self.allocator, object, m),
                }
            }

            if (comptime newObjectAllocates(object)) {
                self.object = Object{ .New = New.init(self.allocator) };
            } else {
                self.object = Object{ .New = New.init(undefined) };
            }

            return &self.object.?.New;
        }

        pub fn mutate(self: *Self) *Mutate {
            if (self.object) |*obj| {
                switch (obj) {
                    .New => |*n| deinitNewType(n),
                    .Mutate => |*m| return m,
                }
            }

            if (comptime mutateObjectAllocates(object)) {
                self.object = Object{ .Mutate = Mutate.init(self.allocator) };
            } else {
                self.object = Object{ .Mutate = Mutate.init(undefined) };
            }

            return &self.object.?.Mutate;
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
            for (object.versions, 0..) |ver, i| {
                tag_fields[i] = .{
                    .name = "V" ++ meta.numFieldName(i),
                    .value = i,
                };

                const Type = WriteNewType(ver);
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
            if (self.version) |ver| {
                switch (ver) {
                    inline else => |val, tag| {
                        if (@intFromEnum(tag) == num) {
                            return &@field(self.version, field_name);
                        }
                        if (comptime newTypeAllocates(field_type)) {
                            deinitNewType(self.allocator, field_type, val);
                        }
                    },
                }
            }

            const FieldType = WriteNewType(field_type);
            if (comptime typeTakesAllocator(field_type)) {
                if (comptime newTypeAllocates(field_type)) {
                    self.version = @unionInit(Version, field_name, FieldType.init(self.allocator));
                } else {
                    self.version = @unionInit(Version, field_name, FieldType.init(undefined));
                }
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
    return WriteOptional(info, WriteNewType, newTypeAllocates);
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

        pub fn elem(self: *Self, index: u64) *Element {
            if (index >= info.len) {
                @panic("index out of bounds");
            }

            if (self.elems[index] == null) {
                if (comptime typeTakesAllocator(info.child.*)) {
                    if (comptime newTypeAllocates(info.child.*)) {
                        self.elems[index] = Element.init(self.allocator);
                    } else {
                        self.elems[index] = Element.init(undefined);
                    }
                } else {
                    self.elems[index] = Element.init();
                }
            }

            return &self.elems[index].?;
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
            if (comptime typeTakesAllocator(info.child.*)) {
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

        pub fn elem(self: *Self, index: u64) *Element {
            if (index >= self.elems.items.len) {
                @panic("index out of bounds");
            }

            return &self.elems.items[index];
        }

        pub fn len(self: *const Self) u64 {
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

        pub fn entry(self: *Self, index: u64) *Entry {
            if (index >= self.entries.items.len) {
                @panic("index out of bounds");
            }

            return &self.entries.items[index];
        }

        pub fn len(self: *Self) u64 {
            return self.entries.items.len;
        }
    };
}

pub fn WriteNewMapEntry(comptime info: def.Type.Map) type {
    return struct {
        allocator: Allocator,
        key: ?Key,
        value: ?Value,

        pub const Key = WriteNewType(info.key.*);
        pub const Value = WriteNewType(info.value.*);
        const Allocator = if (newTypeAllocates(info.key.*) or newTypeAllocates(info.value.*)) std.mem.Allocator else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .key = null,
                .value = null,
            };
        }

        pub fn key(self: *Self) *Key {
            if (self.key == null) {
                if (comptime typeTakesAllocator(info.key.*)) {
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
                if (comptime typeTakesAllocator(info.value.*)) {
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
    return WriteStruct(info, WriteNewType, newTypeAllocates);
}

pub fn WriteNewTuple(comptime info: def.Type.Tuple) type {
    return WriteTuple(info, WriteNewType, newTypeAllocates);
}

pub fn WriteNewUnion(comptime info: def.Type.Union) type {
    return WriteUnion(info, WriteNewType, newTypeAllocates);
}

pub fn WriteMutateObject(comptime object: def.ObjectScheme.Object) type {
    return struct {
        allocator: Allocator,
        version: ?Version,

        pub const Version = blk: {
            var tag_fields: [object.versions.len]std.builtin.Type.EnumField = undefined;
            var union_fields: [tag_fields.len]std.builtin.Type.UnionField = undefined;
            for (object.versions, 0..) |ver, i| {
                tag_fields[i] = .{
                    .name = "V" ++ meta.numFieldName(i),
                    .value = i,
                };

                const Type = WriteMutateType(ver);
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
        const Allocator = if (mutateObjectAllocates(object)) std.mem.Allocator else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .version = null,
            };
        }

        pub fn version(self: *Self, comptime num: comptime_int) *WriteMutateType(object.versions[num]) {
            const field_name = "V" ++ meta.numFieldName(num);
            const field_type = object.versions[num];
            if (self.version) |ver| {
                switch (ver) {
                    inline else => |val, tag| {
                        if (@intFromEnum(tag) == num) {
                            return &@field(self.version, field_name);
                        }
                        if (comptime mutateTypeAllocates(field_type)) {
                            deinitMutateType(self.allocator, field_type, val);
                        }
                    },
                }
            }

            const FieldType = WriteMutateType(field_type);
            if (comptime typeTakesAllocator(field_type)) {
                if (comptime mutateTypeAllocates(field_type)) {
                    self.version = @unionInit(Version, field_name, FieldType.init(self.allocator));
                } else {
                    self.version = @unionInit(Version, field_name, FieldType.init(undefined));
                }
            } else {
                self.version = @unionInit(Version, field_name, FieldType.init());
            }

            return &@field(self.version, field_name);
        }
    };
}

pub fn WriteMutateType(comptime typ: def.Type) type {
    return switch (typ) {
        .Void => WriteVoid,
        .Bool => WriteBool,
        .String => WriteMutateString,
        .Int => |info| WriteInt(info),
        .Float => |info| WriteFloat(info),
        .Optional => |info| WriteMutateOptional(info),
        .Array => |info| WriteMutateArray(info),
        .List => |info| WriteMutateList(info),
        .Map => |info| WriteMutateMap(info),
        .Struct => |info| WriteMutateStruct(info),
        .Tuple => |info| WriteMutateTuple(info),
        .Union => |info| WriteMutateUnion(info),
        .Enum => |info| WriteEnum(info),
        .Ref => WriteRef,
    };
}

pub const WriteMutateString = struct {
    ops: std.ArrayList(serde.MutateString),

    pub fn init(allocator: std.mem.Allocator) WriteMutateString {
        return WriteMutateString{ .ops = std.ArrayList(serde.MutateString).init(allocator) };
    }

    pub fn append(self: *WriteMutateString, str: []const u8) !void {
        try self.ops.append(serde.MutateString{
            .Append = try self.ops.allocator.dupe(u8, str),
        });
    }

    pub fn prepend(self: *WriteMutateString, str: []const u8) !void {
        try self.ops.append(serde.MutateString{
            .Prepend = try self.ops.allocator.dupe(u8, str),
        });
    }

    pub fn insert(self: *WriteMutateString, index: u64, str: []const u8) !void {
        try self.ops.append(serde.MutateString{
            .Insert = .{
                .index = index,
                .str = try self.ops.allocator.dupe(u8, str),
            },
        });
    }

    pub fn delete(self: *WriteMutateString, index: u64, len: u64) !void {
        try self.ops.append(serde.MutateString{
            .Delete = .{
                .index = index,
                .len = len,
            },
        });
    }
};

pub fn WriteMutateOptional(comptime info: def.Type.Optional) type {
    return WriteOptional(info, WriteMutateType, mutateTypeAllocates);
}

pub fn WriteMutateArray(comptime info: def.Type.Array) type {
    return struct {
        ops: std.AutoHashMap(u64, Op),

        pub const Op = struct {
            index: u64,
            elem: Element,
        };
        pub const Element = WriteMutateType(info.child.*);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .ops = std.ArrayList(Op).init(allocator) };
        }

        pub fn elem(self: *Self, index: u64) *Element {
            if (index >= info.len) {
                @panic("index out of bounds");
            }

            const gop = try self.ops.getOrPut(index);
            if (!gop.found_existing) {
                if (comptime typeTakesAllocator(info.child.*)) {
                    if (comptime mutateTypeAllocates(info.child.*)) {
                        gop.value_ptr.* = Op{
                            .index = index,
                            .elem = Element.init(self.ops.allocator),
                        };
                    } else {
                        gop.value_ptr.* = Op{
                            .index = index,
                            .elem = Element.init(undefined),
                        };
                    }
                } else {
                    gop.value_ptr.* = Op{
                        .index = index,
                        .elem = Element.init(),
                    };
                }
            }

            return &gop.value_ptr.elem;
        }
    };
}

pub fn WriteMutateList(comptime info: def.Type.List) type {
    return struct {
        ops: std.ArrayList(Op),

        pub const Op = union(enum) {
            Append: NewElement,
            Prepend: NewElement,
            Insert: struct {
                index: u64,
                elem: NewElement,
            },
            Delete: u64,
            Mutate: struct {
                index: u64,
                elem: MutateElement,
            },
        };
        pub const NewElement = WriteNewType(info.child.*);
        pub const MutateElement = WriteMutateType(info.child.*);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .allocator = allocator };
        }

        pub fn append(self: *Self) !*NewElement {
            const index = self.ops.items.len;
            if (comptime typeTakesAllocator(info.child.*)) {
                if (comptime newTypeAllocates(info.child.*)) {
                    try self.ops.append(Op{ .Append = NewElement.init(self.ops.allocator) });
                } else {
                    try self.ops.append(Op{ .Append = NewElement.init(undefined) });
                }
            } else {
                try self.ops.append(Op{ .Append = NewElement.init() });
            }
            return &self.ops.items[index].Append;
        }

        pub fn prepend(self: *Self) !*NewElement {
            const index = self.ops.items.len;
            if (comptime typeTakesAllocator(info.child.*)) {
                if (comptime newTypeAllocates(info.child.*)) {
                    try self.ops.append(Op{ .Prepend = NewElement.init(self.ops.allocator) });
                } else {
                    try self.ops.append(Op{ .Prepend = NewElement.init(undefined) });
                }
            } else {
                try self.ops.append(Op{ .Prepend = NewElement.init() });
            }
            return &self.ops.items[index].Prepend;
        }

        pub fn insert(self: *Self, index: u64) !*NewElement {
            const op_index = self.ops.items.len;
            if (comptime typeTakesAllocator(info.child.*)) {
                if (comptime newTypeAllocates(info.child.*)) {
                    try self.ops.append(Op{ .Insert = .{
                        .index = index,
                        .elem = NewElement.init(self.ops.allocator),
                    } });
                } else {
                    try self.ops.append(Op{ .Insert = .{
                        .index = index,
                        .elem = NewElement.init(undefined),
                    } });
                }
            } else {
                try self.ops.append(Op{ .Insert = .{
                    .index = index,
                    .elem = NewElement.init(),
                } });
            }
            return &self.ops.items[op_index].Insert.elem;
        }

        pub fn delete(self: *Self, index: u64) !void {
            try self.ops.append(Op{ .Delete = index });
        }

        pub fn mutate(self: *Self, index: u64) !*MutateElement {
            const op_index = self.ops.items.len;
            if (comptime typeTakesAllocator(info.child.*)) {
                if (comptime newTypeAllocates(info.child.*)) {
                    try self.ops.append(Op{ .Mutate = .{
                        .index = index,
                        .elem = MutateElement.init(self.ops.allocator),
                    } });
                } else {
                    try self.ops.append(Op{ .Mutate = .{
                        .index = index,
                        .elem = MutateElement.init(undefined),
                    } });
                }
            } else {
                try self.ops.append(Op{ .Mutate = .{
                    .index = index,
                    .elem = MutateElement.init(),
                } });
            }
            return &self.ops.items[op_index].Mutate.elem;
        }
    };
}

pub fn WriteMutateMap(comptime info: def.Type.Map) type {
    return struct {
        ops: std.ArrayList(Op),

        pub const Op = union(enum) {
            Put: NewEntry,
            Remove: NewKey,
            Mutate: MutateEntry,
        };
        pub const NewEntry = WriteNewMapEntry(info);
        pub const NewKey = WriteNewType(info.key.*);
        pub const MutateEntry = WriteMutateMapEntry(info);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .ops = std.ArrayList(Op).init(allocator) };
        }

        pub fn put(self: *Self) !*NewEntry {
            const index = self.ops.items.len;
            if (comptime newTypeAllocates(info.key.*) or newTypeAllocates(info.value.*)) {
                try self.ops.append(Op{ .Put = NewEntry.init(self.ops.allocator) });
            } else {
                try self.ops.append(Op{ .Put = NewEntry.init(undefined) });
            }
            return &self.ops.items[index].Put;
        }

        pub fn remove(self: *Self) !*NewKey {
            const index = self.ops.items.len;
            if (comptime newTypeAllocates(info.key.*)) {
                try self.ops.append(Op{ .Remove = NewKey.init(self.ops.allocator) });
            } else {
                try self.ops.append(Op{ .Remove = NewKey.init(undefined) });
            }
            return &self.ops.items[index].Remove;
        }

        pub fn mutate(self: *Self) !*MutateEntry {
            const index = self.ops.items.len;
            if (comptime newTypeAllocates(info.key.*)) {
                try self.ops.append(Op{ .Mutate = MutateEntry.init(self.ops.allocator) });
            } else {
                try self.ops.append(Op{ .Mutate = MutateEntry.init(undefined) });
            }
            return &self.ops.items[index].Mutate;
        }
    };
}

pub fn WriteMutateMapEntry(comptime info: def.Type.Map) type {
    return struct {
        allocator: Allocator,
        key: ?Key,
        value: ?Value,

        pub const Key = WriteNewType(info.key.*);
        pub const Value = WriteMutateType(info.value.*);
        const Allocator = if (newTypeAllocates(info.key.*) or mutateTypeAllocates(info.vlaue.*))
            std.mem.Allocator
        else
            void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .key = null,
                .value = null,
            };
        }

        pub fn key(self: *Self) *Key {
            if (self.key == null) {
                if (comptime typeTakesAllocator(info.key.*)) {
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
                if (comptime typeTakesAllocator(info.value.*)) {
                    if (comptime mutateTypeAllocates(info.value.*)) {
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

pub fn WriteMutateStruct(comptime info: def.Type.Struct) type {
    return WriteStruct(info, WriteMutateType, mutateTypeAllocates);
}

pub fn WriteMutateTuple(comptime info: def.Type.Tuple) type {
    return WriteTuple(info, WriteMutateType, mutateTypeAllocates);
}

pub fn WriteMutateUnion(comptime info: def.Type.Union) type {
    return WriteUnion(info, WriteMutateUnionField, newOrMutateTypeAllocates);
}

pub fn WriteMutateUnionField(comptime typ: def.Type) type {
    return struct {
        allocator: Allocator,
        active: ?Active,

        pub const Active = union(enum) {
            New: New,
            Mutate: Mutate,
        };
        pub const New = WriteNewType(typ);
        pub const Mutate = WriteMutateType(typ);
        const Allocator = if (newOrMutateTypeAllocates(typ)) std.mem.Allocator else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .active = null,
            };
        }

        pub fn new(self: *Self) *New {
            if (self.active) |*active| {
                switch (active) {
                    .New => |*n| return n,
                    .Mutate => |*m| {
                        deinitMutateType(m);
                    },
                }
            }

            if (comptime typeTakesAllocator(typ)) {
                if (comptime newTypeAllocates(typ)) {
                    self.active = Active{ .New = New.init(self.allocator) };
                } else {
                    self.active = Active{ .New = New.init(undefined) };
                }
            } else {
                self.active = Active{ .New = New.init() };
            }

            return &self.active.?.New;
        }

        pub fn mutate(self: *Self) *Mutate {
            if (self.active) |*active| {
                switch (active) {
                    .New => |*n| {
                        deinitNewType(n);
                    },
                    .Mutate => |*m| return m,
                }
            }

            if (comptime typeTakesAllocator(typ)) {
                if (comptime mutateTypeAllocates(typ)) {
                    self.active = Active{ .Mutate = New.init(self.allocator) };
                } else {
                    self.active = Active{ .Mutate = New.init(undefined) };
                }
            } else {
                self.active = Active{ .Mutate = New.init() };
            }

            return &self.active.?.Mutate;
        }
    };
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

fn WriteOptional(
    comptime info: def.Type.Optional,
    comptime WriteType: fn (def.Type) type,
    comptime typeAllocates: fn (def.Type) bool,
) type {
    return struct {
        allocator: Allocator,
        opt: Option,

        pub const Option = union(enum) {
            Some: ?WriteNewType(info.child.*),
            None,
        };
        pub const FieldType = WriteType(info.chid.*);
        const Allocator = if (typeAllocates(info.child.*)) std.mem.Allocator else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .value = .None,
            };
        }

        pub fn some(self: *Self) *FieldType {
            if (self.opt == .None or self.opt.Some == null) {
                if (comptime typeTakesAllocator(info.child.*)) {
                    self.opt = Option{
                        .Some = if (comptime typeAllocates(info.child.*))
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

fn WriteStruct(
    comptime info: def.Type.Struct,
    comptime WriteType: fn (def.Type) type,
    comptime typeAllocates: fn (def.Type) bool,
) type {
    return struct {
        allocator: Allocator,
        fields: Fields,

        pub const Fields = blk: {
            var fields: [info.fields.len]std.builtin.Type.Struct = undefined;
            for (info.fields, 0..) |f, i| {
                const Type = ?WriteType(f.type);
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

        const Allocator = for (info.fields) |f| {
            if (newTypeAllocates(f.type)) break std.mem.Allocator;
        } else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
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
                if (comptime typeTakesAllocator(field_type)) {
                    if (comptime typeAllocates(field_type)) {
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

fn WriteTuple(
    comptime info: def.Type.Tuple,
    comptime WriteType: fn (def.Type) type,
    comptime typeAllocates: fn (def.Type) bool,
) type {
    return struct {
        allocator: Allocator,
        fields: Fields,

        pub const Fields = blk: {
            var fields: [info.fields.len]std.builtin.Type.Struct = undefined;
            for (info.fields, 0..) |f, i| {
                const Type = ?WriteType(f);
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

        const Allocator = for (info.fields) |f| {
            if (newTypeAllocates(f)) break std.mem.Allocator;
        } else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
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
                if (comptime typeTakesAllocator(field_type)) {
                    if (comptime typeAllocates(field_type)) {
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

fn WriteUnion(
    comptime info: def.Type.Union,
    comptime WriteType: fn (def.Type) type,
    comptime typeAllocates: fn (def.Type) bool,
) type {
    return struct {
        allocator: Allocator,
        active: ?Fields,

        pub const Fields = blk: {
            var tag_fields: [info.fields.len]std.builtin.Type.EnumField = undefined;
            var fields: [info.fields.len]std.builtin.Type.UnionField = undefined;
            for (info.fields, 0..) |f, i| {
                tag_fields[i] = .{
                    .name = f.name,
                    .value = i,
                };

                const Type = WriteType(f.type);
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
                .active = null,
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

                        if (comptime typeAllocates(field_type)) {
                            deinitNewType(self.allocator, field_type, val);
                        }
                    },
                }
            }

            if (comptime typeTakesAllocator(field_type)) {
                if (comptime typeAllocates(field_type)) {
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
    if (value.version) |*ver| {
        switch (ver) {
            inline else => |*val, tag| {
                const ver_type = object.versions[@intFromEnum(tag)];
                if (comptime newTypeAllocates(ver_type)) {
                    deinitNewType(allocator, ver_type, val);
                }
            },
        }
    }
}

fn deinitNewType(allocator: std.mem.Allocator, comptime typ: def.Type, value: *WriteNewType(typ)) void {
    switch (typ) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => {},
        .String => {
            if (value.str) |str| {
                allocator.free(str);
            }
        },
        .Optional => |info| {
            if (comptime newTypeAllocates(info.child.*)) {
                if (value.opt) |*opt| {
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

fn newOrMutateTypeAllocates(comptime typ: def.Type) bool {
    return newTypeAllocates(typ) or mutateTypeAllocates(typ);
}

fn typeAlwaysTakesAllocator(comptime _: def.Type) bool {
    return true;
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

fn deinitMutateObject(
    allocator: std.mem.Allocator,
    comptime object: def.ObjectScheme.Object,
    value: *WriteMutateObject(object),
) void {
    if (value.version) |*ver| {
        switch (ver) {
            inline else => |*val, tag| {
                const ver_type = object.versions[@intFromEnum(tag)];
                if (comptime newTypeAllocates(ver_type)) {
                    deinitMutateType(allocator, ver_type, val);
                }
            },
        }
    }
}

fn deinitMutateType(allocator: std.mem.Allocator, comptime typ: def.Type, value: *WriteMutateType(typ)) void {
    switch (typ) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => {},
        .String => {
            for (value.ops.items) |op| {
                switch (op) {
                    .Append => |str| {
                        allocator.free(str);
                    },
                    .Prepend => |str| {
                        allocator.free(str);
                    },
                    .Insert => |val| {
                        allocator.free(val.str);
                    },
                    .Delete => {},
                }
            }
            value.ops.deinit();
        },
        .Optional => |info| {
            if (comptime mutateTypeAllocates(info.child.*)) {
                if (value.opt) |*opt| {
                    deinitMutateType(allocator, info.child.*, opt);
                }
            }
        },
        .Array => |info| {
            if (comptime mutateTypeAllocates(info.child.*)) {
                for (value.ops.items) |*op| {
                    deinitMutateType(allocator, info.child.*, &op.elem);
                }
            }
            value.ops.deinit();
        },
        .List => |info| {
            if (comptime newOrMutateTypeAllocates(info.child.*)) {
                for (value.ops.items) |*op| {
                    switch (op) {
                        .Append, .Prepend => |*elem| {
                            deinitNewType(allocator, info.child.*, elem);
                        },
                        .Insert => |*val| {
                            deinitNewType(allocator, info.child.*, &val.elem);
                        },
                        .Delete => {},
                        .Mutate => |*val| {
                            deinitMutateType(allocator, info.child.*, &val.elem);
                        },
                    }
                }
            }
            value.ops.deinit();
        },
        .Map => |info| {
            if (comptime newTypeAllocates(info.key.*) or newOrMutateTypeAllocates(info.value.*)) {
                for (value.ops.items) |*op| {
                    switch (op) {
                        .Put => |*entry| {
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
                        },
                        .Remove => |*key| {
                            if (comptime newTypeAllocates(info.key.*)) {
                                deinitNewType(allocator, info.key.*, key);
                            }
                        },
                        .Mutate => |*entry| {
                            if (comptime newTypeAllocates(info.key.*)) {
                                if (entry.key) |*key| {
                                    deinitNewType(allocator, info.key.*, key);
                                }
                            }
                            if (comptime mutateTypeAllocates(info.value.*)) {
                                if (entry.value) |*val| {
                                    deinitMutateType(allocator, info.value.*, val);
                                }
                            }
                        },
                    }
                }
            }
            value.ops.deinit();
        },
        .Struct => |info| {
            inline for (info.fields) |field| {
                if (comptime mutateTypeAllocates(field.type)) {
                    if (@field(value, field.name)) |*val| {
                        deinitMutateType(allocator, field.type, val);
                    }
                }
            }
        },
        .Tuple => |info| {
            inline for (info.fields, 0..) |f, i| {
                if (comptime mutateTypeAllocates(f)) {
                    if (value[i]) |*val| {
                        deinitMutateType(allocator, f, val);
                    }
                }
            }
        },
        .Union => |info| {
            if (value.active) |*active| {
                switch (active) {
                    inline else => |*val, tag| {
                        const field_type = info.fields[@intFromEnum(tag)].type;
                        if (comptime mutateTypeAllocates(field_type)) {
                            deinitMutateType(allocator, field_type, val);
                        }
                    },
                }
            }
        },
    }
}

fn mutateObjectAllocates(comptime object: def.ObjectScheme.Object) bool {
    return for (object.versions) |ver| {
        if (comptime mutateTypeAllocates(ver)) break true;
    } else false;
}

fn mutateTypeAllocates(comptime typ: def.Type) bool {
    return switch (typ) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => false,
        .String, .Array, .List, .Map => true,
        .Optional => |info| comptime mutateTypeAllocates(info.child.*),
        .Struct => |info| for (info.fields) |field| {
            if (comptime mutateTypeAllocates(field.type)) break true;
        } else false,
        .Tuple => |info| for (info.fields) |field| {
            if (comptime mutateTypeAllocates(field)) break true;
        } else false,
        .Union => |info| for (info.fields) |field| {
            if (comptime mutateTypeAllocates(field.type)) break true;
        } else false,
    };
}

fn typeTakesAllocator(comptime typ: def.Type) bool {
    return switch (typ) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => false,
        else => true,
    };
}
