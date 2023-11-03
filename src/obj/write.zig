const std = @import("std");
const chan = @import("../lib.zig").chan;
const def = @import("../lib.zig").def;
const meta = @import("../meta.zig");
const serde = @import("serde.zig");

pub fn WriteUpdateObject(comptime ObjectRef: type) type {
    return struct {
        allocator: std.mem.Allocator,
        value: ?UpdateObject,

        pub const UpdateObject = union(Tag) {
            New: New,
            Mutate: Mutate,
        };
        pub const New = WriteNewObject(Object);
        pub const Mutate = WriteMutateObject(Object);
        const Tag = std.meta.Tag(serde.UpdateObject(ObjectRef));
        const Object = ObjectRef.def;
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .value = null,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.value) |*val| {
                switch (val.*) {
                    .New => |*n| deinitNewObject(self.allocator, Object, n),
                    .Mutate => |*m| deinitMutateObject(self.allocator, Object, m),
                }
            }
        }

        pub fn new(self: *Self) *New {
            if (self.value) |*val| {
                switch (val.*) {
                    .New => |*n| return n,
                    .Mutate => |*m| deinitMutateObject(self.allocator, Object, m),
                }
            }

            if (comptime objectAllocates(Object, newTypeAllocates)) {
                self.value = UpdateObject{ .New = New.init(self.allocator) };
            } else {
                self.value = UpdateObject{ .New = New.init(undefined) };
            }

            return &self.value.?.New;
        }

        pub fn mutate(self: *Self) *Mutate {
            if (self.value) |*val| {
                switch (val) {
                    .New => |*n| deinitNewType(n),
                    .Mutate => |*m| return m,
                }
            }

            if (comptime objectAllocates(Object, mutateTypeAllocates)) {
                self.value = UpdateObject{ .Mutate = Mutate.init(self.allocator) };
            } else {
                self.value = UpdateObject{ .Mutate = Mutate.init(undefined) };
            }

            return &self.value.?.Mutate;
        }
    };
}

fn WriteNewObject(comptime Object: type) type {
    return WriteObject(Object, WriteNewType, newTypeAllocates, deinitNewType);
}

fn WriteNewType(comptime Type: type) type {
    return switch (def.Type.from(Type).?) {
        .Void => WriteValue(void),
        .Bool => WriteValue(bool),
        .Int => WriteValue(Type),
        .Float => WriteValue(Type),
        .String => WriteNewString,
        .Optional => WriteNewOptional(Type),
        .Array => WriteNewArray(Type),
        .List => WriteNewList(Type),
        .Map => WriteNewMap(Type),
        .Struct => WriteNewStruct(Type),
        .Tuple => WriteNewTuple(Type),
        .Union => WriteNewUnion(Type),
        .Enum => WriteValue(Type),
        .Ref => WriteValue(def.ObjectId),
    };
}

const WriteNewString = struct {
    allocator: std.mem.Allocator,
    value: ?[]const u8,

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

fn WriteNewOptional(comptime Type: type) type {
    return WriteOptional(Type, WriteNewType, newTypeAllocates);
}

fn WriteNewArray(comptime Type: type) type {
    return struct {
        allocator: Allocator,
        elems: [Type.len]?Element,

        pub const Element = WriteNewType(Type.child);
        const Allocator = if (newTypeAllocates(Type.child)) std.mem.Allocator else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .elems = [_]?Element{null} ** Type.len,
            };
        }

        pub fn elem(self: *Self, index: u64) *Element {
            if (index >= Type.len) {
                @panic("index out of bounds");
            }

            if (self.elems[index] == null) {
                if (comptime typeTakesAllocator(Type.child)) {
                    if (comptime newTypeAllocates(Type.child)) {
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

fn WriteNewList(comptime Type: type) type {
    return struct {
        elems: std.ArrayList(Element),

        pub const Element = WriteNewType(Type.child);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .elems = std.ArrayList(Element).init(allocator) };
        }

        pub fn append(self: *Self) !*Element {
            if (comptime typeTakesAllocator(Type.child)) {
                if (comptime newTypeAllocates(Type.child)) {
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

fn WriteNewMap(comptime Type: type) type {
    return struct {
        elems: std.ArrayList(Entry),

        pub const Entry = WriteNewMapEntry(Type);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .elems = std.ArrayList(Entry).init(allocator) };
        }

        pub fn put(self: *Self) !*Entry {
            if (comptime newTypeAllocates(Type.key) or newTypeAllocates(Type.value)) {
                try self.elems.append(Entry.init(self.elems.allocator));
            } else {
                try self.elems.append(Entry.init(undefined));
            }
            return &self.elems.items[self.len() - 1];
        }

        pub fn entry(self: *Self, index: u64) *Entry {
            if (index >= self.elems.items.len) {
                @panic("index out of bounds");
            }

            return &self.elems.items[index];
        }

        pub fn len(self: *Self) u64 {
            return self.elems.items.len;
        }
    };
}

fn WriteNewMapEntry(comptime Type: type) type {
    return struct {
        allocator: Allocator,
        key: Key,
        value: Value,

        pub const Key = WriteNewType(Type.key);
        pub const Value = WriteNewType(Type.value);
        const Allocator = if (newTypeAllocates(Type.key) or newTypeAllocates(Type.value)) std.mem.Allocator else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            var self = Self{
                .allocator = allocator,
                .key = undefined,
                .value = undefined,
            };
            if (comptime typeTakesAllocator(Type.key)) {
                if (comptime newTypeAllocates(Type.key)) {
                    self.key = Key.init(self.allocator);
                } else {
                    self.key = Key.init(undefined);
                }
            } else {
                self.key = Key.init();
            }
            if (comptime typeTakesAllocator(Type.value)) {
                if (comptime newTypeAllocates(Type.value)) {
                    self.value = Value.init(self.allocator);
                } else {
                    self.value = Value.init(undefined);
                }
            } else {
                self.value = Value.init();
            }
            return self;
        }
    };
}

fn WriteNewStruct(comptime Type: type) type {
    return WriteStruct(Type, WriteNewType, newTypeAllocates);
}

fn WriteNewTuple(comptime Type: type) type {
    return WriteTuple(Type, WriteNewType, newTypeAllocates);
}

fn WriteNewUnion(comptime Type: type) type {
    return WriteUnion(Type, WriteNewType, newTypeAllocates);
}

fn WriteMutateObject(comptime Object: type) type {
    return WriteObject(Object, WriteMutateType, mutateTypeAllocates, deinitMutateType);
}

fn WriteMutateType(comptime Type: type) type {
    return switch (def.Type.from(Type).?) {
        .Void => WriteValue(void),
        .Bool => WriteValue(bool),
        .Int => WriteValue(Type),
        .Float => WriteValue(Type),
        .String => WriteMutateString,
        .Optional => WriteMutateOptional(Type),
        .Array => WriteMutateArray(Type),
        .List => WriteMutateList(Type),
        .Map => WriteMutateMap(Type),
        .Struct => WriteMutateStruct(Type),
        .Tuple => WriteMutateTuple(Type),
        .Union => WriteMutateUnion(Type),
        .Enum => WriteValue(Type),
        .Ref => WriteValue(def.ObjectId),
    };
}

const WriteMutateString = struct {
    elems: std.ArrayList(Op),

    const Op = serde.MutateStringOp;

    pub fn init(allocator: std.mem.Allocator) WriteMutateString {
        return WriteMutateString{ .elems = std.ArrayList(serde.MutateString).init(allocator) };
    }

    pub fn append(self: *WriteMutateString, str: []const u8) !void {
        try self.elems.append(Op{
            .Append = try self.elems.allocator.dupe(u8, str),
        });
    }

    pub fn prepend(self: *WriteMutateString, str: []const u8) !void {
        try self.elems.append(Op{
            .Prepend = try self.elems.allocator.dupe(u8, str),
        });
    }

    pub fn insert(self: *WriteMutateString, index: u64, str: []const u8) !void {
        try self.elems.append(Op{
            .Insert = .{
                .index = index,
                .str = try self.elems.allocator.dupe(u8, str),
            },
        });
    }

    pub fn delete(self: *WriteMutateString, index: u64, len: u64) !void {
        try self.elems.append(Op{
            .Delete = .{
                .index = index,
                .len = len,
            },
        });
    }
};

fn WriteMutateOptional(comptime Type: type) type {
    return WriteOptional(Type, WriteMutateType, mutateTypeAllocates);
}

fn WriteMutateArray(comptime Type: type) type {
    return struct {
        elems: std.ArrayList(Op),

        pub const Op = struct {
            index: u64,
            elem: Element,
        };
        pub const Element = WriteMutateType(Type.child);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .elems = std.ArrayList(Op).init(allocator) };
        }

        pub fn elem(self: *Self, index: u64) *Element {
            if (index >= Type.len) {
                @panic("index out of bounds");
            }

            const gop = try self.elems.getOrPut(index);
            if (!gop.found_existing) {
                if (comptime typeTakesAllocator(Type.child)) {
                    if (comptime mutateTypeAllocates(Type.child)) {
                        gop.value_ptr.* = Op{
                            .index = index,
                            .elem = Element.init(self.elems.allocator),
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

fn WriteMutateList(comptime Type: type) type {
    return struct {
        elems: std.ArrayList(Op),

        pub const Op = union(enum) {
            Append: NewElement,
            Prepend: NewElement,
            Insert: InsertOp,
            Delete: u64,
            Mutate: MutateOp,
        };
        pub const InsertOp = struct {
            index: u64,
            elem: NewElement,
        };
        pub const MutateOp = struct {
            index: u64,
            elem: MutateElement,
        };
        pub const NewElement = WriteNewType(Type.child);
        pub const MutateElement = WriteMutateType(Type.child);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .allocator = allocator };
        }

        pub fn append(self: *Self) !*NewElement {
            const index = self.elems.items.len;
            if (comptime typeTakesAllocator(Type.child)) {
                if (comptime newTypeAllocates(Type.child)) {
                    try self.elems.append(Op{ .Append = NewElement.init(self.elems.allocator) });
                } else {
                    try self.elems.append(Op{ .Append = NewElement.init(undefined) });
                }
            } else {
                try self.elems.append(Op{ .Append = NewElement.init() });
            }
            return &self.elems.items[index].Append;
        }

        pub fn prepend(self: *Self) !*NewElement {
            const index = self.elems.items.len;
            if (comptime typeTakesAllocator(Type.child)) {
                if (comptime newTypeAllocates(Type.child)) {
                    try self.elems.append(Op{ .Prepend = NewElement.init(self.elems.allocator) });
                } else {
                    try self.elems.append(Op{ .Prepend = NewElement.init(undefined) });
                }
            } else {
                try self.elems.append(Op{ .Prepend = NewElement.init() });
            }
            return &self.elems.items[index].Prepend;
        }

        pub fn insert(self: *Self, index: u64) !*NewElement {
            const op_index = self.elems.items.len;
            if (comptime typeTakesAllocator(Type.child)) {
                if (comptime newTypeAllocates(Type.child)) {
                    try self.elems.append(Op{ .Insert = .{
                        .index = index,
                        .elem = NewElement.init(self.elems.allocator),
                    } });
                } else {
                    try self.elems.append(Op{ .Insert = .{
                        .index = index,
                        .elem = NewElement.init(undefined),
                    } });
                }
            } else {
                try self.elems.append(Op{ .Insert = .{
                    .index = index,
                    .elem = NewElement.init(),
                } });
            }
            return &self.elems.items[op_index].Insert.elem;
        }

        pub fn delete(self: *Self, index: u64) !void {
            try self.elems.append(Op{ .Delete = index });
        }

        pub fn mutate(self: *Self, index: u64) !*MutateElement {
            const op_index = self.elems.items.len;
            if (comptime typeTakesAllocator(Type.child)) {
                if (comptime newTypeAllocates(Type.child)) {
                    try self.elems.append(Op{ .Mutate = .{
                        .index = index,
                        .elem = MutateElement.init(self.elems.allocator),
                    } });
                } else {
                    try self.elems.append(Op{ .Mutate = .{
                        .index = index,
                        .elem = MutateElement.init(undefined),
                    } });
                }
            } else {
                try self.elems.append(Op{ .Mutate = .{
                    .index = index,
                    .elem = MutateElement.init(),
                } });
            }
            return &self.elems.items[op_index].Mutate.elem;
        }
    };
}

fn WriteMutateMap(comptime Type: type) type {
    return struct {
        elems: std.ArrayList(Op),

        pub const Op = union(enum) {
            Put: NewEntry,
            Remove: NewKey,
            Mutate: MutateEntry,
        };
        pub const NewEntry = WriteNewMapEntry(Type);
        pub const NewKey = WriteNewType(Type.key);
        pub const MutateEntry = WriteMutateMapEntry(Type);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .elems = std.ArrayList(Op).init(allocator) };
        }

        pub fn put(self: *Self) !*NewEntry {
            const index = self.elems.items.len;
            if (comptime newTypeAllocates(Type.key) or newTypeAllocates(Type.value)) {
                try self.elems.append(Op{ .Put = NewEntry.init(self.elems.allocator) });
            } else {
                try self.elems.append(Op{ .Put = NewEntry.init(undefined) });
            }
            return &self.elems.items[index].Put;
        }

        pub fn remove(self: *Self) !*NewKey {
            const index = self.elems.items.len;
            if (comptime newTypeAllocates(Type.key)) {
                try self.elems.append(Op{ .Remove = NewKey.init(self.elems.allocator) });
            } else {
                try self.elems.append(Op{ .Remove = NewKey.init(undefined) });
            }
            return &self.elems.items[index].Remove;
        }

        pub fn mutate(self: *Self) !*MutateEntry {
            const index = self.elems.items.len;
            if (comptime newTypeAllocates(Type.key)) {
                try self.elems.append(Op{ .Mutate = MutateEntry.init(self.elems.allocator) });
            } else {
                try self.elems.append(Op{ .Mutate = MutateEntry.init(undefined) });
            }
            return &self.elems.items[index].Mutate;
        }
    };
}

fn WriteMutateMapEntry(comptime Type: type) type {
    return struct {
        allocator: Allocator,
        key: Key,
        value: Value,

        pub const Key = WriteNewType(Type.key);
        pub const Value = WriteMutateType(Type.value);
        const Allocator = if (newTypeAllocates(Type.key) or mutateTypeAllocates(Type.value))
            std.mem.Allocator
        else
            void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            var self = Self{
                .allocator = allocator,
                .key = undefined,
                .value = undefined,
            };
            if (comptime typeTakesAllocator(Type.key)) {
                if (comptime newTypeAllocates(Type.key)) {
                    self.key = Key.init(self.allocator);
                } else {
                    self.key = Key.init(undefined);
                }
            } else {
                self.key = Key.init();
            }

            if (comptime typeTakesAllocator(Type.value)) {
                if (comptime mutateTypeAllocates(Type.value)) {
                    self.value = Value.init(self.allocator);
                } else {
                    self.value = Value.init(undefined);
                }
            } else {
                self.value = Value.init();
            }

            return self;
        }
    };
}

fn WriteMutateStruct(comptime Type: type) type {
    return WriteStruct(Type, WriteMutateType, mutateTypeAllocates);
}

fn WriteMutateTuple(comptime Type: type) type {
    return WriteTuple(Type, WriteMutateType, mutateTypeAllocates);
}

fn WriteMutateUnion(comptime Type: type) type {
    return WriteUnion(Type, WriteMutateUnionField, newOrMutateTypeAllocates);
}

fn WriteMutateUnionField(comptime Type: type) type {
    return struct {
        allocator: Allocator,
        active: ?Active,

        pub const Active = union(enum) {
            New: New,
            Mutate: Mutate,
        };
        pub const New = WriteNewType(Type);
        pub const Mutate = WriteMutateType(Type);
        const Allocator = if (newOrMutateTypeAllocates(Type)) std.mem.Allocator else void;
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

            if (comptime typeTakesAllocator(Type)) {
                if (comptime newTypeAllocates(Type)) {
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

            if (comptime typeTakesAllocator(Type)) {
                if (comptime mutateTypeAllocates(Type)) {
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

fn WriteObject(
    comptime Object: type,
    comptime WriteType: fn (type) type,
    comptime typeAllocates: fn (type) bool,
    comptime deinitVersion: anytype,
) type {
    return struct {
        allocator: Allocator,
        active: ?Version,

        pub const Version = blk: {
            var tag_fields: [Object.versions.len]std.builtin.Type.EnumField = undefined;
            var fields: [tag_fields.len]std.builtin.Type.UnionField = undefined;
            for (Object.versions, 0..) |Ver, i| {
                tag_fields[i] = .{
                    .name = "V" ++ meta.numFieldName(i),
                    .value = i,
                };

                const FieldType = WriteType(Ver);
                fields[i] = .{
                    .name = tag_fields[i].name,
                    .type = FieldType,
                    .alignment = @alignOf(FieldType),
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
        const Allocator = if (objectAllocates(Object, typeAllocates)) std.mem.Allocator else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .active = null,
            };
        }

        pub fn version(self: *Self, comptime num: comptime_int) *WriteType(Object.versions[num]) {
            const field_name = "V" ++ comptime meta.numFieldName(num);
            const field_type = Object.versions[num];
            if (self.active) |*active| {
                const val = &@field(active, field_name);
                if (@intFromEnum(active.*) == num) {
                    return val;
                }
                if (comptime typeAllocates(field_type)) {
                    deinitVersion(self.allocator, field_type, val);
                }
            }

            const FieldType = WriteType(field_type);
            if (comptime typeTakesAllocator(field_type)) {
                if (comptime typeAllocates(field_type)) {
                    self.active = @unionInit(Version, field_name, FieldType.init(self.allocator));
                } else {
                    self.active = @unionInit(Version, field_name, FieldType.init(undefined));
                }
            } else {
                self.active = @unionInit(Version, field_name, FieldType.init());
            }

            return &@field(self.active.?, field_name);
        }
    };
}

fn WriteValue(comptime Type: type) type {
    return struct {
        value: ?Type,

        const Value = Type;
        const Self = @This();

        pub fn init() Self {
            return Self{ .value = null };
        }

        pub fn set(self: *Self, value: Type) void {
            self.value = value;
        }
    };
}

fn WriteOptional(
    comptime Type: type,
    comptime WriteType: fn (type) type,
    comptime typeAllocates: fn (type) bool,
    comptime deinitChild: anytype,
) type {
    return struct {
        allocator: Allocator,
        opt: ?Option,

        pub const Option = union(enum) {
            Some: WriteNewType(Child),
            None,
        };
        pub const FieldType = WriteType(Child);
        const Allocator = if (typeAllocates(Child)) std.mem.Allocator else void;
        const Child = std.meta.Child(Type);
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .value = .None,
            };
        }

        pub fn some(self: *Self) *FieldType {
            if (self.opt == null or self.opt.? == .None) {
                if (comptime typeTakesAllocator(Child)) {
                    if (comptime typeAllocates(Child)) {
                        self.opt = Option{ .Some = FieldType.init(self.allocator) };
                    } else {
                        self.opt = Option{ .Some = FieldType.init(undefined) };
                    }
                } else {
                    self.opt = Option{ .Some = FieldType.init() };
                }
            }
            return &self.opt.Some.?;
        }

        pub fn none(self: *Self) void {
            if (self.opt) |*opt| {
                switch (opt) {
                    .Some => |*val| {
                        if (comptime typeAllocates(Child)) {
                            deinitChild(self.allocator, Child, val);
                        }
                    },
                    .None => {},
                }
            }
        }
    };
}

fn WriteStruct(
    comptime Type: type,
    comptime WriteType: fn (type) type,
    comptime typeAllocates: fn (type) bool,
) type {
    return struct {
        allocator: Allocator,
        fields: Fields,

        pub const Fields = blk: {
            const info = @typeInfo(Type).Struct;
            var fields: [info.fields.len]std.builtin.Type.Struct = undefined;
            for (info.fields, 0..) |f, i| {
                const FT = ?WriteType(f.type);
                fields[i] = .{
                    .name = f.name,
                    .type = FT,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(FT),
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

        const Allocator = for (std.meta.fields(Type)) |f| {
            if (newTypeAllocates(f.type)) break std.mem.Allocator;
        } else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            var fields: Fields = undefined;
            inline for (std.meta.fields(Type)) |f| {
                @field(fields, f.name) = null;
            }
            return Self{
                .allocator = allocator,
                .fields = fields,
            };
        }

        pub fn field(self: *Self, comptime name: std.meta.FieldEnum(Fields)) *FieldType(name) {
            const field_type = std.meta.fields(Type)[@intFromEnum(name)].type;
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
    comptime Type: type,
    comptime WriteType: fn (type) type,
    comptime typeAllocates: fn (type) bool,
) type {
    return struct {
        allocator: Allocator,
        fields: Fields,

        pub const Fields = blk: {
            const info = @typeInfo(Type).Struct;
            var fields: [info.fields.len]std.builtin.Type.Struct = undefined;
            for (info.fields, 0..) |f, i| {
                const FT = ?WriteType(f.type);
                fields[i] = .{
                    .name = meta.numFieldName(i),
                    .type = FT,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(FT),
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

        const Allocator = for (std.meta.fields(Type)) |f| {
            if (newTypeAllocates(f)) break std.mem.Allocator;
        } else void;
        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            var fields: Fields = undefined;
            inline for (0..std.meta.fields(Type).len) |i| {
                fields[i] = null;
            }
            return Self{
                .allocator = allocator,
                .fields = fields,
            };
        }

        pub fn field(self: *Self, comptime index: comptime_int) *FieldType(index) {
            const field_type = std.meta.fields(Type)[index].type;
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
    comptime Type: type,
    comptime WriteType: fn (type) type,
    comptime typeAllocates: fn (type) bool,
) type {
    return struct {
        allocator: Allocator,
        active: ?Fields,

        pub const Fields = blk: {
            const info = @typeInfo(Type).Union;
            var tag_fields: [info.fields.len]std.builtin.Type.EnumField = undefined;
            var fields: [info.fields.len]std.builtin.Type.UnionField = undefined;
            for (info.fields, 0..) |f, i| {
                tag_fields[i] = .{
                    .name = f.name,
                    .value = i,
                };

                const FT = WriteType(f.type);
                fields[i] = .{
                    .name = f.name,
                    .type = FT,
                    .alignment = @alignOf(FT),
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

        const Allocator = for (std.meta.fields(Type)) |f| {
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
            const field_type = std.meta.fields(Type)[@intFromEnum(name)].type;
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

fn objectAllocates(comptime Object: type, comptime typeAllocates: fn (type) bool) bool {
    return for (Object.versions) |Ver| {
        if (comptime typeAllocates(Ver)) break true;
    } else false;
}

fn newOrMutateTypeAllocates(comptime Type: type) bool {
    return newTypeAllocates(Type) or mutateTypeAllocates(Type);
}

fn newTypeAllocates(comptime Type: type) bool {
    return switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => false,
        .String, .List, .Map => true,
        .Optional => comptime newTypeAllocates(std.meta.Child(Type)),
        .Array => comptime newTypeAllocates(std.meta.Child(Type)),
        .Struct, .Tuple => for (std.meta.fields(Type)) |field| {
            if (comptime newTypeAllocates(field.type)) break true;
        } else false,
        .Union => for (std.meta.fields(Type)) |field| {
            if (comptime newTypeAllocates(field.type)) break true;
        } else false,
    };
}

fn mutateTypeAllocates(comptime Type: type) bool {
    return switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => false,
        .String, .Array, .List, .Map => true,
        .Optional => comptime mutateTypeAllocates(std.meta.Child(Type)),
        .Struct, .Tuple => for (std.meta.fields(Type)) |field| {
            if (comptime mutateTypeAllocates(field.type)) break true;
        } else false,
        .Union => for (std.meta.fields(Type)) |field| {
            if (comptime mutateTypeAllocates(field.type)) break true;
        } else false,
    };
}

fn typeTakesAllocator(comptime Type: type) bool {
    return switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => false,
        else => true,
    };
}

fn typeAlwaysTakesAllocator(comptime _: def.Type) bool {
    return true;
}

fn deinitNewObject(
    allocator: std.mem.Allocator,
    comptime Object: type,
    obj: *WriteNewObject(Object),
) void {
    if (obj.active) |*ver| {
        switch (ver.*) {
            inline else => |*val, tag| {
                const ver_type = Object.versions[@intFromEnum(tag)];
                if (comptime newTypeAllocates(ver_type)) {
                    deinitNewType(allocator, ver_type, val);
                }
            },
        }
    }
}

fn deinitNewType(allocator: std.mem.Allocator, comptime Type: type, value: *WriteNewType(Type)) void {
    switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => {},
        .String => {
            if (value.str) |str| {
                allocator.free(str);
            }
        },
        .Optional => {
            const Child = std.meta.Child(Type);
            if (comptime newTypeAllocates(Child)) {
                if (value.opt) |*opt| {
                    deinitNewType(allocator, Child, opt);
                }
            }
        },
        .Array => {
            const Child = std.meta.Child(Type);
            if (comptime newTypeAllocates(Child)) {
                for (value) |*elem| {
                    if (elem) |*e| {
                        deinitNewType(allocator, Child, e);
                    }
                }
            }
        },
        .List => {
            const Child = std.meta.Child(Type);
            if (comptime newTypeAllocates(Child)) {
                for (value.elems.items) |*elem| {
                    deinitNewType(allocator, Child, elem);
                }
            }
            value.elems.deinit();
        },
        .Map => {
            if (comptime newTypeAllocates(Type.key) or newTypeAllocates(Type.value)) {
                for (value.entries.items) |*entry| {
                    if (comptime newTypeAllocates(Type.key)) {
                        deinitNewType(allocator, Type.key, &entry.key);
                    }

                    if (comptime newTypeAllocates(Type.value)) {
                        deinitNewType(allocator, Type.value, &entry.value);
                    }
                }
            }
            value.entries.deinit();
        },
        .Struct, .Tuple => {
            inline for (std.meta.fields(Type)) |field| {
                if (comptime newTypeAllocates(field.type)) {
                    if (@field(value, field.name)) |*val| {
                        deinitNewType(allocator, field.type, val);
                    }
                }
            }
        },
        .Union => {
            if (value.active) |*active| {
                switch (active) {
                    inline else => |*val, tag| {
                        const field_type = std.meta.fields(Type)[@intFromEnum(tag)].type;
                        if (comptime newTypeAllocates(field_type)) {
                            deinitNewType(allocator, field_type, val);
                        }
                    },
                }
            }
        },
    }
}

fn deinitMutateObject(
    allocator: std.mem.Allocator,
    comptime Object: type,
    obj: *WriteMutateObject(Object),
) void {
    if (obj.active) |*ver| {
        switch (ver.*) {
            inline else => |*val, tag| {
                const ver_type = Object.versions[@intFromEnum(tag)];
                if (comptime newTypeAllocates(ver_type)) {
                    deinitMutateType(allocator, ver_type, val);
                }
            },
        }
    }
}

fn deinitMutateType(allocator: std.mem.Allocator, comptime Type: type, value: *WriteMutateType(Type)) void {
    switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => {},
        .String => {
            for (value.elems.items) |op| {
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
            value.elems.deinit();
        },
        .Optional => {
            const Child = std.meta.Child(Type);
            if (comptime mutateTypeAllocates(Child)) {
                if (value.opt) |*opt| {
                    deinitMutateType(allocator, Child, opt);
                }
            }
        },
        .Array => {
            const Child = std.meta.Child(Type);
            if (comptime mutateTypeAllocates(Child)) {
                for (value.elems.items) |*op| {
                    deinitMutateType(allocator, Child, &op.elem);
                }
            }
            value.elems.deinit();
        },
        .List => {
            const Child = std.meta.Child(Type);
            if (comptime newOrMutateTypeAllocates(Child)) {
                for (value.elems.items) |*op| {
                    switch (op) {
                        .Append, .Prepend => |*elem| {
                            deinitNewType(allocator, Child, elem);
                        },
                        .Insert => |*val| {
                            deinitNewType(allocator, Child, &val.elem);
                        },
                        .Delete => {},
                        .Mutate => |*val| {
                            deinitMutateType(allocator, Child, &val.elem);
                        },
                    }
                }
            }
            value.elems.deinit();
        },
        .Map => {
            if (comptime newTypeAllocates(Type.key) or newOrMutateTypeAllocates(Type.value)) {
                for (value.elems.items) |*op| {
                    switch (op) {
                        .Put => |*entry| {
                            if (comptime newTypeAllocates(Type.key)) {
                                deinitNewType(allocator, Type.key, &entry.key);
                            }
                            if (comptime newTypeAllocates(Type.value)) {
                                deinitNewType(allocator, Type.value, &entry.value);
                            }
                        },
                        .Remove => |*key| {
                            if (comptime newTypeAllocates(Type.key)) {
                                deinitNewType(allocator, Type.key, key);
                            }
                        },
                        .Mutate => |*entry| {
                            if (comptime newTypeAllocates(Type.key)) {
                                deinitNewType(allocator, Type.key, &entry.key);
                            }
                            if (comptime mutateTypeAllocates(Type.value)) {
                                deinitMutateType(allocator, Type.value, &entry.value);
                            }
                        },
                    }
                }
            }
            value.elems.deinit();
        },
        .Struct, .Tuple => {
            inline for (std.meta.fields(Type)) |field| {
                if (comptime mutateTypeAllocates(field.type)) {
                    if (@field(value, field.name)) |*val| {
                        deinitMutateType(allocator, field.type, val);
                    }
                }
            }
        },
        .Union => {
            if (value.active) |*active| {
                switch (active) {
                    inline else => |*val, tag| {
                        const field_type = std.meta.fields(Type)[@intFromEnum(tag)].type;
                        if (comptime mutateTypeAllocates(field_type)) {
                            deinitMutateType(allocator, field_type, val);
                        }
                    },
                }
            }
        },
    }
}

pub const WriteError = error{
    UnionValueNotSet,
    ArrayElementNotSet,
    OptionalValueNotSet,
    StructFieldNotSet,
    ValueNotSet,
};

pub fn write(
    comptime ObjectRef: type,
    value: *const WriteUpdateObject(ObjectRef),
    out: *std.ArrayList(u8),
) !void {
    try chan.writeAdapted(
        serde.UpdateObject(ObjectRef),
        WriteError,
        UpdateObjectAdapter(ObjectRef).init(value),
        out,
    );
}

fn UpdateObjectAdapter(comptime ObjectRef: type) type {
    return struct {
        val: *const Value,

        const Value = WriteUpdateObject(ObjectRef);
        const Tag = std.meta.Tag(serde.UpdateObject(ObjectRef));
        const Self = @This();

        pub fn init(val: *const Value) Self {
            return Self{ .val = val };
        }

        pub fn tag(self: Self) !Tag {
            if (self.val.value) |*val| {
                return val.*;
            }
            return error.UnionValueNotSet;
        }

        pub fn value(self: Self, comptime t: Tag) !FieldAdapter(t) {
            if (self.val.value) |*val| {
                return FieldAdapter(t).init(&@field(val, @tagName(t)));
            }
            return error.UnionValueNotSet;
        }

        fn FieldAdapter(comptime t: Tag) type {
            return switch (t) {
                .New => NewObjectAdapter(ObjectRef.def),
                .Mutate => MutateObjectAdapter(ObjectRef.def),
            };
        }
    };
}

fn NewObjectAdapter(comptime Object: type) type {
    return ObjectAdapter(
        Object,
        WriteNewObject,
        serde.NewObject,
        NewTypeAdapter,
    );
}

fn NewTypeAdapter(comptime Type: type) type {
    return switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .String, .Enum, .Ref => NewValueAdapter(Type),
        .Optional => NewOptionalAdapter(Type),
        .Array => NewArrayAdapter(Type),
        .List => NewListAdapter(Type),
        .Map => NewMapAdapter(Type),
        .Struct, .Tuple => NewStructOrTupleAdapter(Type),
        .Union => NewUnionAdapter(Type),
    };
}

fn NewValueAdapter(comptime Type: type) type {
    return ValueAdapter(WriteNewType(Type), serde.NewType(Type));
}

fn NewOptionalAdapter(comptime Type: type) type {
    return OptionalAdapter(WriteNewOptional(Type), NewTypeAdapter(std.meta.Child(Type)));
}

fn NewArrayAdapter(comptime Type: type) type {
    return struct {
        val: *const Value,

        const ElemAdapter = NewTypeAdapter(Type.child);
        const Value = WriteNewArray(Type);
        const Self = @This();

        pub fn init(val: *const Value) Self {
            return Self{ .val = val };
        }

        pub fn elem(self: Self, index: usize) !ElemAdapter {
            if (self.val.elems[index]) |*e| {
                return ElemAdapter.init(e);
            }
            return error.ArrayElementNotSet;
        }
    };
}

fn NewListAdapter(comptime Type: type) type {
    return SliceAdapter(WriteNewList(Type), NewTypeAdapter(Type.child));
}

fn NewMapAdapter(comptime Type: type) type {
    return SliceAdapter(
        WriteNewMap(Type),
        StructAdapter(
            WriteNewMapEntry(Type),
            struct {
                key: Type.key,
                value: Type.value,
            },
            WriteNewType,
            NewTypeAdapter,
            false,
        ),
    );
}

fn NewStructOrTupleAdapter(comptime Type: type) type {
    return StructAdapter(WriteNewStruct(Type), Type, WriteNewType, NewTypeAdapter, false);
}

fn NewUnionAdapter(comptime Type: type) type {
    return UnionAdapter(
        WriteNewUnion(Type),
        std.meta.Tag(serde.NewUnion(Type)),
        Type,
        NewTypeAdapter,
    );
}

fn MutateObjectAdapter(comptime Object: type) type {
    return ObjectAdapter(
        Object,
        WriteMutateObject,
        serde.MutateObject,
        MutateTypeAdapter,
    );
}

fn MutateTypeAdapter(comptime Type: type) type {
    return switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => MutateValueAdapter(Type),
        .String => MutateStringAdapter,
        .Optional => MutateOptionalAdapter(Type),
        .Array => MutateArrayAdapter(Type),
        .List => MutateListAdapter(Type),
        .Map => MutateMapAdapter(Type),
        .Struct, .Tuple => MutateStructOrTupleAdapter(Type),
        .Union => MutateUnionAdapter(Type),
    };
}

fn MutateValueAdapter(comptime Type: type) type {
    return ValueAdapter(WriteMutateType(Type), serde.MutateType(Type));
}

const MutateStringAdapter = SliceAdapter(WriteMutateString, DirectUnionAdapter(serde.MutateStringOp, struct {
    fn FieldAdapter(comptime T: type) type {
        return if (T == []const u8) DirectValueAdapter(T) else DirectStructAdapter(T, DirectValueAdapter);
    }
}));

fn MutateOptionalAdapter(comptime Type: type) type {
    return OptionalAdapter(WriteMutateOptional(Type), MutateTypeAdapter(std.meta.Child(Type)));
}

fn MutateArrayAdapter(comptime Type: type) type {
    const Value = WriteMutateArray(Type);
    const OpFieldAdapter = struct {
        fn FieldAdapter(comptime T: type) type {
            return if (T == Value.Element) MutateTypeAdapter(Type.child) else DirectValueAdapter(T);
        }
    }.FieldAdapter;
    return SliceAdapter(Value, DirectStructAdapter(Value.Op, OpFieldAdapter));
}

fn MutateListAdapter(comptime Type: type) type {
    const Value = WriteMutateList(Type);
    const OpFieldAdapter = struct {
        fn FieldAdapter(comptime T: type) type {
            return if (T == Value.NewElement)
                NewTypeAdapter(Type.child)
            else if (T == Value.MutateElement)
                MutateTypeAdapter(Type.child)
            else if (T == Value.InsertOp or T == Value.MutateOp)
                DirectStructAdapter(T, FieldAdapter)
            else
                DirectValueAdapter(T);
        }
    }.FieldAdapter;
    return SliceAdapter(Value, DirectUnionAdapter(Value.Op, OpFieldAdapter));
}

fn MutateMapAdapter(comptime Type: type) type {
    const Value = WriteMutateMap(Type);
    const OpFieldAdapter = struct {
        fn FieldAdapter(comptime T: type) type {
            if (T == Value.NewEntry or T == Value.MutateEntry)
                DirectStructAdapter(T, FieldAdapter)
            else if (T == Value.NewKey)
                NewTypeAdapter(Type.key)
            else if (T == Value.NewEntry.Value)
                NewTypeAdapter(Type.value)
            else if (T == Value.MutateEntry.Value)
                MutateTypeAdapter(Type.value)
            else
                @compileError("unexpected type");
        }
    }.FieldAdapter;
    return SliceAdapter(Value, DirectUnionAdapter(Value.Op, OpFieldAdapter));
}

fn MutateStructOrTupleAdapter(comptime Type: type) type {
    return StructAdapter(WriteMutateStruct(Type), Type, WriteMutateType, MutateTypeAdapter, true);
}

fn MutateUnionAdapter(comptime Type: type) type {
    return UnionAdapter(
        WriteMutateUnion(Type),
        std.meta.Tag(serde.MutateUnion(Type)),
        Type,
        MutateTypeAdapter,
    );
}

fn ObjectAdapter(
    comptime Object: type,
    comptime WriteObjectType: fn (type) type,
    comptime ObjectAdapted: fn (type) type,
    comptime VersionAdapter: fn (type) type,
) type {
    var fields: [Object.versions.len]std.builtin.Type.UnionField = undefined;
    for (0..Object.versions.len) |i| {
        fields[i] = .{
            .name = meta.numFieldName(i),
            .type = Object.versions[i],
            .alignment = @alignOf(Object.versions[i]),
        };
    }
    const Fields = @Type(.{
        .Union = .{
            .layout = .Auto,
            .tag_type = null,
            .fields = &fields,
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    });

    return UnionAdapter(
        WriteObjectType(Object),
        std.meta.Tag(ObjectAdapted(Object)),
        Fields,
        VersionAdapter,
    );
}

fn OptionalAdapter(comptime Value: type, comptime ChildAdapter: type) type {
    return struct {
        val: *const Value,

        const Self = @This();

        pub fn init(val: *const Value) Self {
            return Self{ .val = val };
        }

        pub fn value(self: Self) !?ChildAdapter {
            if (self.val.opt) |*opt| {
                return switch (opt) {
                    .Some => |*val| ChildAdapter.init(val),
                    .None => null,
                };
            }
            return error.OptionalValueNotSet;
        }
    };
}

fn SliceAdapter(comptime Value: type, comptime ElemAdapter: type) type {
    return struct {
        val: *const Value,

        const Self = @This();

        pub fn init(val: *const Value) Self {
            return Self{ .val = val };
        }

        pub fn len(self: Self) !usize {
            return self.val.elems.items.len;
        }

        pub fn elem(self: Self, index: usize) !ElemAdapter {
            return ElemAdapter.init(&self.val.elems.items[index]);
        }
    };
}

fn StructAdapter(
    comptime Value: type,
    comptime Fields: type,
    comptime FieldValue: fn (type) type,
    comptime FieldAdapter: fn (type) type,
    comptime allow_null: bool,
) type {
    return struct {
        val: *const Value,

        const Self = @This();

        pub fn init(val: *const Value) Self {
            return Self{ .val = val };
        }

        pub fn field(self: Self, comptime index: comptime_int) !FieldAdapterAt(index) {
            return FieldAdapterAt(index).init(&@field(self.val.fields, fieldInfo(index).name));
        }

        fn fieldInfo(comptime index: comptime_int) std.builtin.Type.StructField {
            var i = 0;
            for (std.meta.fields(Fields)) |f| {
                if (def.Type.from(f.type) == null) continue;
                if (i == index) return f;
                i += 1;
            }
            @compileError("struct field index is invalid");
        }

        fn FieldAdapterAt(comptime index: comptime_int) type {
            const info = fieldInfo(index);
            return StructFieldAdapter(FieldValue(info.type), FieldAdapter(info.type), allow_null);
        }
    };
}

fn TupleAdapter(
    comptime Value: type,
    comptime Fields: type,
    comptime FieldValue: fn (type) type,
    comptime FieldAdapter: fn (type) type,
    comptime allow_null: bool,
) type {
    return struct {
        val: *const Value,

        const Self = @This();

        pub fn init(val: *const Value) Self {
            return Self{ .val = val };
        }

        pub fn field(self: Self, comptime index: comptime_int) !FieldAdapterAt(index) {
            return FieldAdapterAt(index).init(&self.val.fields[index]);
        }

        fn FieldAdapterAt(comptime index: comptime_int) type {
            var i = 0;
            for (std.meta.fields(Fields)) |f| {
                if (def.Type.from(f.type) == null) continue;
                if (i == index) {
                    return StructFieldAdapter(FieldValue(f.type), FieldAdapter(f.type), allow_null);
                }
                i += 1;
            }
            @compileError("tuple field index is invalid");
        }
    };
}

fn StructFieldAdapter(comptime Value: type, comptime FieldAdapter: type, comptime allow_null: bool) type {
    return struct {
        val: *const ?Value,

        const Self = @This();

        pub fn init(val: *const ?Value) Self {
            return Self{ .val = val };
        }

        pub fn value(self: Self) !if (allow_null) ?FieldAdapter else FieldAdapter {
            if (self.val) |*val| {
                return FieldAdapter.init(val);
            }
            return if (allow_null) null else error.StructFieldNotSet;
        }
    };
}

fn UnionAdapter(
    comptime Value: type,
    comptime Tag: type,
    comptime Fields: type,
    comptime FieldAdapter: fn (type) type,
) type {
    return struct {
        val: *const Value,

        const Self = @This();

        pub fn init(val: *const Value) Self {
            return Self{ .val = val };
        }

        pub fn tag(self: Self) !Tag {
            if (self.val.active) |*val| {
                return @enumFromInt(@intFromEnum(val.*));
            }
            return error.UnionValueNotSet;
        }

        pub fn value(self: Self, comptime t: Tag) !FieldAdapterTag(t) {
            if (self.val.active) |*val| {
                return FieldAdapterTag(t).init(&@field(val, @tagName(t)));
            }
            return error.UnionValueNotSet;
        }

        fn fieldInfo(comptime t: Tag) std.builtin.Type.UnionField {
            comptime {
                const info = @typeInfo(Fields).Union;
                var i = 0;
                for (info.fields) |f| {
                    if (def.Type.from(f.type) == null) continue;
                    if (@intFromEnum(t) == i) {
                        return f;
                    }
                    i += 1;
                }
                @compileError("union field tag is invalid");
            }
        }

        fn FieldAdapterTag(comptime t: Tag) type {
            const info = fieldInfo(t);
            return FieldAdapter(info.type);
        }
    };
}

fn ValueAdapter(comptime Value: type, comptime Adapted: type) type {
    return struct {
        val: *const Value,

        const Self = @This();

        pub fn init(val: *const Value) Self {
            return Self{ .val = val };
        }

        pub fn value(self: Self) !Adapted {
            if (self.val.value) |val| {
                return val;
            }
            return error.ValueNotSet;
        }
    };
}

fn DirectValueAdapter(comptime Type: type) type {
    return struct {
        val: Type,

        const Self = @This();

        pub fn init(val: Type) Self {
            return Self{ .val = val };
        }

        pub fn value(self: Self) !Type {
            return self.val;
        }
    };
}

fn DirectStructAdapter(comptime Type: type, comptime FieldAdapter: fn (type) type) type {
    return struct {
        val: Type,

        const Self = @This();

        pub fn init(val: Type) Self {
            return Self{ .val = val };
        }

        pub fn field(self: Self, comptime index: comptime_int) !FieldAdapterAt(index) {
            const field_name = std.meta.fields(Type)[index].name;
            return FieldAdapterAt(index).init(@field(self.val, field_name));
        }

        fn FieldAdapterAt(comptime index: comptime_int) type {
            return FieldAdapter(std.meta.fields(Type)[index].type);
        }
    };
}

fn DirectUnionAdapter(comptime Type: type, comptime FieldAdapter: fn (type) type) type {
    return struct {
        val: Type,

        const Tag = std.meta.Tag(Type);
        const Self = @This();

        pub fn init(val: Type) Self {
            return Self{ .val = val };
        }

        pub fn tag(self: Self) !Tag {
            return self.val;
        }

        pub fn value(self: Self, comptime t: Tag) !FieldAdapterTag(t) {
            const field_name = std.meta.fields(Type)[@intFromEnum(t)].name;
            return FieldAdapterTag(t).init(@field(self.val, field_name));
        }

        fn FieldAdapterTag(comptime t: Tag) type {
            return FieldAdapter(std.meta.fields(Type)[@intFromEnum(t)].type);
        }
    };
}

const TestObj = def.Scheme("scheme", .{
    def.Object("Obj", .{
        void,
        //bool,
        //u32,
        //f32,
        //def.String,
        //?def.String,
        //def.Array(10, u32),
        //def.List(u32),
        //def.Map(u32, u32),
        //struct {
        //    f1: u32,
        //    f2: bool,
        //},
        //struct {
        //    u32,
        //    bool,
        //},
        //union(enum) {
        //    f1: u32,
        //    f2: bool,
        //},
        //enum {
        //    f1,
        //    f2,
        //},
        //def.This("Obj"),
    }),
}).ref("Obj");
const TestWriter = WriteUpdateObject(TestObj);

test "write new void" {
    var writer = TestWriter.init(std.testing.allocator);
    defer writer.deinit();

    _ = writer.new()
        .version(0);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try write(TestObj, &writer, &out);

    const view = chan.read(serde.UpdateObject(TestObj), out.items);

    try std.testing.expect(view.tag() == .New);
}
