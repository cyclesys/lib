const std = @import("std");
const chan = @import("../lib.zig").chan;
const def = @import("../lib.zig").def;
const obj = @import("../lib.zig").obj;
const meta = @import("../meta.zig");
const serde = @import("serde.zig");

pub const Error = error{
    SchemeNotDefined,
    ObjectNotDefined,
    VersionNotDefined,
    ObjectNotFound,
    InvalidStringOp,
    InvalidOptionalOp,
    InvalidArrayOp,
    InvalidListOp,
    InvalidMapOp,
    InvalidUnionOp,
} || std.mem.Allocator.Error;

pub fn Store(comptime Index: type) type {
    return struct {
        allocator: std.mem.Allocator,
        slots: Slots,

        const Slots = blk: {
            var scheme_types: [Index.schemes.len]type = undefined;
            for (Index.scheme.types, 0..) |Scheme, i| {
                var object_types: [Scheme.types.len]type = undefined;
                for (Scheme.types, 0..) |Object, ii| {
                    var version_types: [Object.versions.len]type = undefined;
                    for (Object.versions, 0..) |Version, iii| {
                        version_types[iii] = Slot(Version);
                    }
                    object_types[ii] = meta.Tuple(version_types);
                }
                scheme_types[i] = meta.Tuple(object_types);
            }
            break :blk meta.Tuple(scheme_types);
        };
        fn Slot(comptime Version: type) type {
            return std.AutoHashMap(u64, Value(Version));
        }
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            var slots: Slots = undefined;
            inline for (Index.scheme_types, 0..) |Scheme, i| {
                inline for (Scheme.types, 0..) |Object, ii| {
                    inline for (0..Object.versions.len) |iii| {
                        slots[i][ii][iii] = Slot.init(allocator);
                    }
                }
            }
            return Self{ .slots = slots };
        }

        pub fn deinit(self: *Self) void {
            inline for (Index.scheme_types, 0..) |Scheme, i| {
                inline for (Scheme.types, 0..) |Object, ii| {
                    inline for (0..Object.versions.len) |iii| {
                        self.slots[i][ii][iii].deinit();
                    }
                }
            }
            self.* = undefined;
        }

        pub fn add(self: *Self, id: obj.ObjectId, bytes: []const u8) !void {
            try self.withVersionSlot(id, bytes, addVersion);
        }

        fn addVersion(
            self: *Self,
            comptime Version: type,
            slot: anytype,
            id: obj.ObjectId,
            bytes: []const u8,
        ) Error!void {
            const gop = try slot.getOrPut(@bitCast(id.source));
            if (comptime typeAllocates(Version)) {
                if (gop.found_existing) {
                    deinitValue(self.allocator, Version, .val, gop.value_ptr);
                }
            }
            gop.value_ptr.* = try initValue(self.allocator, Version, .val, chan.read(serde.NewType(Version), bytes));
        }

        pub fn update(self: *Self, id: obj.ObjectId, bytes: []const u8) Error!void {
            try self.withVersionSlot(id, bytes, updateVersion);
        }

        fn updateVersion(
            self: *Self,
            comptime Version: type,
            slot: anytype,
            id: obj.ObjectId,
            bytes: []const u8,
        ) Error!void {
            if (slot.getPtr(@bitCast(id.source))) |ptr| {
                try updateValue(self.allocator, Version, chan.read(serde.MutateType(Version), bytes), ptr);
            } else {
                return error.ObjectNotFound;
            }
        }

        pub fn remove(self: *Self, id_bits: u128) Error!void {
            const id: obj.ObjectId = @bitCast(id_bits);
            try self.withVersionSlot(id, @as(void, undefined), removeVersion);
        }

        fn removeVersion(
            self: *Self,
            comptime Version: type,
            slot: anytype,
            id: obj.ObjectId,
            _: void,
        ) Error!void {
            if (slot.getPtr(@bitCast(id.source))) |ptr| {
                try deinitValue(self.allocator, Version, .val, ptr);
                _ = slot.remove(@bitCast(id.source));
            } else {
                return error.ObjectNotFound;
            }
        }

        fn withVersionSlot(
            self: *Self,
            id: obj.ObjectId,
            args: anytype,
            f: fn (*Self, comptime type, anytype, id: obj.ObjectId, @TypeOf(args)) Error!void,
        ) Error!void {
            if (id.type.scheme >= Index.schemes.len) {
                return error.SchemeNotDefined;
            }

            const SchemeEnum = meta.NumEnum(Index.schemes.len);
            const scheme_id: SchemeEnum = @enumFromInt(id.type.scheme);
            switch (scheme_id) {
                inline else => |scheme_tag| {
                    const scheme_slot = @intFromEnum(scheme_tag);
                    const Scheme = Index.schemes[scheme_slot];

                    if (id.type.name >= Scheme.types.len) {
                        return error.ObjectNotDefined;
                    }

                    const ObjectEnum = meta.NumEnum(Scheme.types.len);
                    const object_id: ObjectEnum = @enumFromInt(id.type.name);
                    switch (object_id) {
                        inline else => |object_tag| {
                            const object_slot = @intFromEnum(object_tag);
                            const Object = Scheme.types[object_slot];

                            if (id.type.version >= Object.versions.len) {
                                return error.VersionNotDefined;
                            }

                            const VersionEnum = meta.NumEnum(Object.versions.len);
                            const version_id: VersionEnum = @enumFromInt(id.type.version);
                            switch (version_id) {
                                inline else => |version_tag| {
                                    const version_slot = @intFromEnum(version_tag);
                                    const Version = Scheme.types[version_slot];

                                    const slot: *Slot(Version) = &self.slots[scheme_slot][object_slot][version_slot];
                                    f(self, Version, slot, id, args);
                                },
                            }
                        },
                    }
                },
            }
        }
    };
}

pub fn Value(comptime Type: type) type {
    return switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum => Type,
        .String => std.ArrayList(u8),
        .Optional => ?Value(std.meta.Child(Type)),
        .Array => [Type.len]Value(Type.child),
        .List => std.ArrayList(Value(Type.child)),
        .Map => MapValue(Type),
        .Struct => meta.RemapStruct(meta.fields(Type), Value),
        .Tuple => meta.RemapTuple(meta.fields(Type), Value),
        .Union => meta.RemapUnion(meta.fields(Type), Value),
        .Ref => obj.ObjectId,
    };
}

fn MapValue(comptime Type: type) type {
    return std.HashMap(
        KeyValue(Type.key),
        Value(Type.value),
        KeyValueContext(Type.key),
        std.hash_map.default_max_load_percentage,
    );
}

fn KeyValue(comptime Type: type) type {
    return switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum => Type,
        .String => []const u8,
        .Optional => ?KeyValue(std.meta.Child(Type)),
        .Array => [Type.len]KeyValue(Type.child),
        .List, .Map => @compileError("List and Map are not supported as Map.key types"),
        .Struct => meta.RemapStruct(meta.fields(Type), KeyValue),
        .Tuple => meta.RemapTuple(meta.fields(Type), KeyValue),
        .Union => meta.RemapUnion(meta.fields(Type), KeyValue),
        .Ref => u128,
    };
}

fn KeyValueContext(comptime Type: type) type {
    return struct {
        const Key = KeyValue(Type);

        pub fn hash(_: @This(), key: Key) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hashKeyValue(Type, key, &hasher);
        }

        pub fn eql(_: @This(), a: Key, b: Key) bool {
            return keyValueEql(Type, a, b);
        }
    };
}

const InitMode = enum {
    val,
    key,
    key_dupe,
};

fn initValue(
    allocator: std.mem.Allocator,
    comptime Type: type,
    comptime mode: InitMode,
    view: chan.View(serde.NewType(Type)),
    out: if (mode == .val) *Value(Type) else *KeyValue(Type),
) std.mem.Allocator.Error!void {
    switch (comptime def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum => {
            out.* = view;
        },
        .String => {
            switch (mode) {
                .val => {
                    out.* = std.ArrayList(u8).init(allocator);
                    try out.appendSlice(view);
                },
                .key => {
                    out.* = view;
                },
                .key_dupe => {
                    out.* = try allocator.dupe(u8, view);
                },
            }
        },
        .Optional => {
            if (view) |child_view| {
                try initValue(allocator, std.meta.Child(Type), mode, child_view, &out.*.?);
            } else {
                out.* = null;
            }
        },
        .Array => {
            for (out.*, 0..) |*elem, i| {
                try initValue(allocator, Type.child, mode, view.elem(i), elem);
            }
        },
        .List => {
            if (mode != .val) @compileError("list type unsupported here");

            out.* = std.ArrayList(Value(Type.child)).init(allocator);

            const len = view.len();
            try out.resize(len);

            for (0..len) |i| {
                try initValue(allocator, Type.child, .val, view.elem(i), &out.items[i]);
            }
        },
        .Map => {
            if (mode != .val) @compileError("map type unsupported here");

            out.* = MapValue(Type).init(allocator);

            const len = view.len();
            try out.ensureTotalCapacity(len);

            for (0..len) |i| {
                try mapPut(allocator, Type, view.elem(i), out);
            }
        },
        .Struct => {
            inline for (meta.fields(Type), 0..) |f, i| {
                try initValue(allocator, f.type, mode, view.field(@enumFromInt(i)), &@field(out, f.name));
            }
        },
        .Tuple => {
            inline for (meta.fields(Type), 0..) |f, i| {
                try initValue(allocator, f.type, mode, view.field(i), &out[i]);
            }
        },
        .Union => {
            switch (view.tag()) {
                inline else => |tag| {
                    const f = meta.fields(Type)[@intFromEnum(tag)];

                    out.* = @unionInit(Value(Type), f.name, undefined);
                    try initValue(allocator, f.type, mode, view.value(tag), &@field(out, f.name));
                },
            }
        },
        .Ref => {
            out.* = @bitCast(view);
        },
    }
}

fn deinitValue(
    allocator: std.mem.Allocator,
    comptime Type: type,
    comptime mode: InitMode,
    value: if (mode == .val) *Value(Type) else *KeyValue(Type),
) void {
    switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => {},
        .String => {
            switch (mode) {
                .val => {
                    value.deinit();
                },
                .key => {},
                .key_dupe => {
                    allocator.free(value.*);
                },
            }
        },
        .Optional => {
            if (value.*) |*child_value| {
                deinitValue(allocator, std.meta.Child(Type), mode, child_value);
            }
        },
        .Array => {
            for (value.*) |*elem| {
                deinitValue(allocator, Type.child, mode, elem);
            }
        },
        .List => {
            if (comptime typeAllocates(Type.child)) {
                for (value.items) |*elem| {
                    deinitValue(allocator, Type.child, .val, elem);
                }
            }
            value.deinit();
        },
        .Map => {
            if (comptime typeAllocates(Type.key) or typeAllocates(Type.value)) {
                var iter = value.iterator();
                while (iter.next()) |entry| {
                    if (comptime typeAllocates(Type.key)) {
                        deinitValue(allocator, Type.key, .key_dupe, entry.key_ptr);
                    }
                    if (comptime typeAllocates(Type.value)) {
                        deinitValue(allocator, Type.value, .val, entry.value_ptr);
                    }
                }
            }
            value.deinit();
        },
        .Struct, .Tuple => {
            inline for (meta.fields(Type)) |f| {
                if (comptime typeAllocates(f.type)) {
                    deinitValue(allocator, f.type, mode, &@field(value, f.name));
                }
            }
        },
        .Union => {
            switch (value.*) {
                inline else => |*val, tag| {
                    const f = meta.fields(Type)[@intFromEnum(tag)];
                    if (comptime typeAllocates(f.type)) {
                        deinitValue(allocator, f.type, mode, val);
                    }
                },
            }
        },
    }
    value.* = undefined;
}

fn updateValue(
    allocator: std.mem.Allocator,
    comptime Type: type,
    view: chan.View(serde.MutateType(Type)),
    out: *Value(Type),
) Error!void {
    switch (comptime def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => {
            try initValue(allocator, Type, view, out);
        },
        .String => {
            for (0..view.len()) |i| {
                const op = view.elem(i);
                switch (op.tag()) {
                    .Append => {
                        const str = op.value(.Append);
                        try out.appendSlice(str);
                    },
                    .Prepend => {
                        const str = op.value(.Prepend);
                        try out.insertSlice(0, str);
                    },
                    .Insert => {
                        const ins = op.value(.Insert);
                        const index = ins.field(.index);
                        const str = ins.field(.str);
                        try out.insertSlice(index, str);
                    },
                    .Delete => {
                        const del = op.value(.Delete);
                        const index = del.field(.index);
                        const len = del.field(.len);

                        if (index >= out.items.len) {
                            return error.InvalidStringOp;
                        }

                        // Check if this is simply truncating the string.
                        if (index + len >= out.items.len) {
                            out.items.len = index;
                        } else {
                            // TODO: optimize this for large strings by allocating a copy of the src string and using
                            // @memcpy. What needs figuring out is at what string size should this happen.
                            const source = out.items[index + len ..];
                            const dest = out.items[index..][0..source.len];
                            std.mem.copyForwards(u8, dest, source);
                            out.items.len -= len;
                        }
                    },
                }
            }
        },
        .Optional => {
            switch (view.tag()) {
                .New => {
                    if (out.* != null) {
                        return error.InvalidOptionalOp;
                    }
                    try initValue(allocator, std.meta.Child(Type), view.value(.New), &out.*.?);
                },
                .Mutate => {
                    if (out.* == null) {
                        return error.InvalidOptionalOp;
                    }
                    try updateValue(allocator, std.meta.Child(Type), view.value(.Mutate), &out.*.?);
                },
                .None => {
                    if (out.* == null) {
                        return error.InvalidOptionalOp;
                    }
                    if (comptime typeAllocates(std.meta.Child(Type))) {
                        deinitValue(std.meta.Child(Type), &out.*.?);
                    }
                    out.* = null;
                },
            }
        },
        .Array => {
            for (0..view.len()) |i| {
                const op = view.elem(i);
                const index = op.field(.index);

                if (index >= Type.len) {
                    return error.InvalidArrayOp;
                }

                try updateValue(allocator, Type.child, op.field(.elem), &out[index]);
            }
        },
        .List => {
            for (0..view.len()) |i| {
                const op = view.elem(i);
                switch (op.tag()) {
                    .Append => {
                        const elem_out = try out.addOne();
                        try initValue(allocator, Type.child, op.value(.Append), elem_out);
                    },
                    .Prepend => {
                        try out.insert(0, undefined);
                        try initValue(allocator, Type.child, op.value(.Prepend), &out.items[0]);
                    },
                    .Insert => {
                        const ins = op.value(.Insert);
                        const index = ins.field(.index);

                        if (index > out.items.len) {
                            return error.InvalidListOp;
                        }

                        try out.insert(index, undefined);
                        try initValue(allocator, Type.child, ins.field(.elem), &out.items[index]);
                    },
                    .Delete => {
                        const index = op.value(.Delete);

                        if (index >= out.items.len) {
                            return error.InvalidListOp;
                        }

                        if (comptime typeAllocates(Type.child)) {
                            deinitValue(Type.child, &out.items[index]);
                        }

                        _ = try out.orderedRemove(index);
                    },
                    .Mutate => {
                        const mut = op.value(.Mutate);
                        const index = mut.field(.index);
                        if (index >= out.items.len) {
                            return error.InvalidListOp;
                        }

                        try updateValue(allocator, Type.child, mut.field(.elem), &out.items[index]);
                    },
                }
            }
        },
        .Map => {
            for (0..view.len()) |i| {
                const op = view.elem(i);
                switch (op.tag()) {
                    .Put => {
                        try mapPut(allocator, Type, op.value(.Put), out);
                    },
                    .Remove => {
                        var key: Value(Type.key) = undefined;
                        try initValue(allocator, Type.key, .key, op.value(.Remove), &key);

                        if (out.getPtr(key)) |val| {
                            if (comptime typeAllocates(Type.key)) {
                                deinitValue(allocator, Type.key, .key_dupe, out.getKeyPtr(key).?);
                            }
                            if (comptime typeAllocates(Type.value)) {
                                deinitValue(allocator, Type.value, .val, val);
                            }
                        } else {
                            return error.InvalidMapOp;
                        }

                        _ = out.remove(key);
                    },
                    .Mutate => {
                        const mut = op.value(.Mutate);

                        var key: Value(Type.key) = undefined;
                        try initValue(allocator, Type.key, .key, mut.field(key), &key);

                        if (out.getPtr(key)) |val| {
                            try updateValue(allocator, Type.value, mut.field(.value), val);
                        } else {
                            return error.InvalidMapOp;
                        }
                    },
                }
            }
        },
        .Struct => {
            inline for (meta.fields(Type), 0..) |f, i| {
                const field_view = view.field(@enumFromInt(i));
                if (field_view.value()) |val_view| {
                    try updateValue(allocator, f.type, val_view, @field(out, f.name));
                }
            }
        },
        .Tuple => {
            inline for (meta.fields(Type), 0..) |f, i| {
                const field_view = view.field(i);
                if (field_view.value()) |val_view| {
                    try updateValue(allocator, f.type, val_view, out[i]);
                }
            }
        },
        .Union => {
            switch (view.tag()) {
                inline else => |tag| {
                    const f = meta.fields(Type)[@intFromEnum(tag)];

                    const val_view = view.value(tag);
                    switch (val_view.tag()) {
                        .New => {
                            if (comptime typeAllocates(Type)) {
                                deinitValue(allocator, Type, .val, out);
                            }

                            out.* = @unionInit(Value(Type), f.name, undefined);
                            try initValue(allocator, f.type, val_view.value(.New), &@field(out, f.name));
                        },
                        .Mutate => {
                            if (out != tag) {
                                return error.InvalidUnionOp;
                            }

                            try updateValue(allocator, f.type, val_view.value(.Mutate), &@field(out, f.name));
                        },
                    }
                },
            }
        },
    }
}

fn mapPut(
    allocator: std.mem.Allocator,
    comptime Type: type,
    view: chan.View(serde.NewMapEntry(Type)),
    out: *MapValue(Type),
) Error!void {
    var key: KeyValue(Type.key) = undefined;
    try initValue(allocator, Type.key, .key_dupe, view.field(.key), &key);

    const gop = try out.getOrPut(key);
    if (gop.found_existing) {
        return error.InvalidMapOp;
    }

    try initValue(allocator, Type.value, .val, view.field(.value), gop.value_ptr);
}

fn hashKeyValue(comptime Type: type, value: KeyValue(Type), hasher: *std.hash.Wyhash) void {
    switch (comptime def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => std.hash.autoHash(hasher, value),
        .String => {
            hasher.update(value);
        },
        .Optional => {
            if (value) |v| {
                hashKeyValue(std.meta.Child(Type), v, hasher);
            }
        },
        .Array => {
            for (value) |v| {
                hashKeyValue(Type.child, v, hasher);
            }
        },
        .Struct => {
            inline for (meta.fields(Type)) |f| {
                hashKeyValue(f.type, @field(value, f.name), hasher);
            }
        },
        .Tuple => {
            inline for (meta.fields(Type), 0..) |f, i| {
                hashKeyValue(f.type, value[i], hasher);
            }
        },
        .Union => {
            switch (value) {
                inline else => |v, tag| {
                    const f = meta.fields(Type)[@intFromEnum(tag)];
                    hashKeyValue(f.type, v, hasher);
                },
            }
        },
        else => @compileError("unsupported type"),
    }
}

fn keyValueEql(comptime Type: type, a: KeyValue(Type), b: KeyValue(Type)) bool {
    return switch (comptime def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => a == b,
        .String => std.mem.eql(u8, a, b),
        .Optional => blk: {
            if (a == null and b == null) break :blk true;
            if (a == null or b == null) break :blk false;
            break :blk keyValueEql(std.meta.Child(Type), a.?, b.?);
        },
        .Array => blk: {
            for (a, b) |ae, be| {
                if (!keyValueEql(Type.child, ae, be)) break :blk false;
            }
            break :blk true;
        },
        .Struct => blk: {
            inline for (meta.fields(Type)) |f| {
                if (!keyValueEql(f.type, @field(a, f.name), @field(b, f.name))) break :blk false;
            }
            break :blk true;
        },
        .Tuple => blk: {
            inline for (meta.fields(Type), 0..) |f, i| {
                if (!keyValueEql(f.type, a[i], b[i])) break :blk false;
            }
            break :blk true;
        },
        .Union => blk: {
            switch (a) {
                inline else => |val, tag| {
                    if (b != tag) break :blk false;
                    const f = meta.fields(Type)[@intFromEnum(tag)];
                    break :blk keyValueEql(f.type, val, @field(b, f.name));
                },
            }
        },
        else => @compileError("unsupported type"),
    };
}

fn typeAllocates(comptime Type: type) bool {
    return switch (def.Type.from(Type).?) {
        .Void, .Bool, .Int, .Float, .Enum, .Ref => false,
        .String, .List, .Map => true,
        .Optional => typeAllocates(std.meta.Child(Type)),
        .Array => typeAllocates(Type.child),
        .Struct, .Tuple, .Union => for (meta.fields(Type)) |f| {
            if (typeAllocates(f.type)) break true;
        } else false,
    };
}
