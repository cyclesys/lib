const std = @import("std");
const define = @import("../define.zig");
const definition = @import("../definition.zig");
const serde = @import("../serde.zig");
const super = @import("../object.zig");
const SharedMem = @import("../SharedMem.zig");

const meta = @import("meta.zig");
const read = @import("read.zig");

pub const Error = error{
    SchemeNotDefined,
    ObjectNotDefined,
} || std.mem.Allocator.Error;

pub fn ObjectIndex(comptime scheme_fns: anytype) type {
    return struct {
        allocator: std.mem.Allocator,
        slots: Slots,

        pub const schemes = blk: {
            var scheme_types: []const type = &[_]type{};
            for (scheme_fns) |SchemeFn| {
                const Scheme = SchemeFn(define.This);
                scheme_types = definition.ObjectScheme.mergeTypes(scheme_types, &.{Scheme});

                const dependencies = definition.ObjectScheme.dependencies(Scheme);
                scheme_types = definition.ObjectScheme.mergeTypes(scheme_types, dependencies);
            }

            var obj_schemes: [scheme_types.len]definition.ObjectScheme = undefined;
            for (scheme_types, 0..) |Scheme, i| {
                obj_schemes[i] = definition.ObjectScheme.from(Scheme);
            }

            break :blk definition.ObjectScheme.mergeSchemes(obj_schemes[0..]);
        };

        const Slots = blk: {
            var scheme_slot_types: [schemes.len]type = undefined;
            for (schemes, 0..) |scheme, i| {
                var object_slot_types: [scheme.objects.len]type = undefined;
                for (0..scheme.objects.len) |ii| {
                    object_slot_types[ii] = MemMap;
                }
                scheme_slot_types[i] = meta.Tuple(object_slot_types);
            }
            break :blk meta.Tuple(scheme_slot_types);
        };

        pub fn objInfo(
            comptime scheme: []const u8,
            comptime name: []const u8,
        ) definition.ObjectScheme.Object {
            comptime {
                for (schemes) |sch| {
                    if (!std.mem.eql(u8, scheme, sch.name)) {
                        continue;
                    }

                    for (sch.objects) |info| {
                        if (std.mem.eql(u8, name, info.name)) {
                            return info;
                        }
                    }
                }
            }
        }

        const ObjSlot = struct {
            scheme: comptime_int,
            type: comptime_int,
        };

        fn objTypeSlot(comptime Obj: type) ObjSlot {
            return objSlot(Obj.scheme.name, Obj.def.name);
        }

        fn objSlot(comptime scheme: []const u8, comptime name: []const u8) ObjSlot {
            comptime {
                for (schemes, 0..) |sch, i| {
                    if (std.mem.eql(u8, scheme, sch.name)) {
                        for (sch.objects, 0..) |obj, ii| {
                            if (std.mem.eql(u8, name, obj.name)) {
                                return ObjSlot{
                                    .scheme = i,
                                    .type = ii,
                                };
                            }
                        }
                    }
                }

                @compileError(name ++ " is not defined wihtin this ObjectIndex.");
            }
        }

        const MemMap = std.AutoHashMap(u64, SharedMem);
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            var slots: Slots = undefined;
            inline for (schemes, 0..) |scheme, i| {
                const SchemeSlot = @typeInfo(Slots).Struct.fields[i].type;
                var slot: SchemeSlot = undefined;
                inline for (0..scheme.objects.len) |ii| {
                    slot[ii] = MemMap.init(allocator);
                }
                slots[i] = slot;
            }
            return Self{
                .allocator = allocator,
                .slots = slots,
            };
        }

        pub fn deinit(self: *Self) void {
            inline for (schemes, 0..) |scheme, i| {
                inline for (0..scheme.objects.len) |ii| {
                    var map = &self.slots[i][ii];
                    defer map.deinit();

                    var values = map.valueIterator();
                    while (values.next()) |mem| {
                        mem.deinit();
                    }
                }
            }
        }

        pub fn put(self: *Self, obj: super.Object) Error!void {
            const map = try self.getMap(obj.type);
            var old = try map.fetchPut(@bitCast(obj.id), obj.mem);
            if (old) |*kv| {
                const mem = &kv.value;
                mem.deinit();
            }
        }

        pub fn remove(self: *Self, type_id: super.TypeId, obj_id: super.ObjectId) Error!void {
            const map = try self.getMap(type_id);
            const removed = map.fetchRemove(@bitCast(obj_id));
            if (removed) |kv| {
                kv.value.deinit();
            }
        }

        fn getMap(self: *Self, id: super.TypeId) Error!*MemMap {
            if (id.scheme >= schemes.len) {
                return error.SchemeNotDefined;
            }

            const SchemeEnum = meta.NumEnum(schemes.len);
            switch (@as(SchemeEnum, @enumFromInt(id.scheme))) {
                inline else => |scheme_val| {
                    const scheme_slot = @intFromEnum(scheme_val);
                    const scheme = schemes[scheme_slot];
                    if (id.name >= scheme.objects.len) {
                        return error.ObjectNotDefined;
                    }

                    const ObjectEnum = meta.NumEnum(scheme.objects.len);
                    switch (@as(ObjectEnum, @enumFromInt(id.name))) {
                        inline else => |object_val| {
                            const object_slot = @intFromEnum(object_val);
                            return &self.slots[scheme_slot][object_slot];
                        },
                    }
                },
            }
        }

        pub fn get(self: *Self, comptime Obj: type, id: super.ObjectId) ?View(Obj) {
            const slot = comptime objTypeSlot(Obj);
            const map = &self.slots[slot.scheme][slot.type];
            const mem = map.getPtr(@bitCast(id));
            if (mem) |m| {
                return read.readObject(
                    Self,
                    Obj.scheme.name,
                    Obj.def.name,
                    self,
                    m.view,
                );
            }
            return null;
        }

        pub fn getResolve(
            self: *Self,
            type_id: super.TypeId,
            obj_id: super.ObjectId,
            context: anytype,
            f: anytype,
        ) !blk: {
            const err = "`f` must be a fn of type `fn (comptime Obj: type, view: View(Obj), ctx: @TypeOf(context)) 'some return type'";
            switch (@typeInfo(@TypeOf(f))) {
                .Fn => |info| {
                    if (info.params.len != 3 or
                        info.params[0].type == null or info.params[0].type.? != type or
                        info.params[1].type != null or
                        info.params[2].type == null or info.params[2].type.? != @TypeOf(context))
                    {
                        @compileError(err);
                    }

                    break :blk switch (@typeInfo(info.return_type.?)) {
                        .ErrorUnion => |return_type| return_type.payload,
                        else => info.return_type.?,
                    };
                },
                else => @compileError(err),
            }
        } {
            if (type_id.scheme >= schemes.len) {
                return error.SchemeNotDefined;
            }

            const SchemeEnum = meta.NumEnum(schemes.len);
            switch (@as(SchemeEnum, @enumFromInt(type_id.scheme))) {
                inline else => |scheme_val| {
                    const scheme_slot = @intFromEnum(scheme_val);
                    const scheme = schemes[scheme_slot];

                    if (type_id.name >= scheme.objects.len) {
                        return error.ObjectNotDefined;
                    }

                    const SchemeFn = for (scheme_fns) |Fn| {
                        const Scheme = Fn(define.This);
                        if (std.mem.eql(Scheme.name, scheme.name)) {
                            break Fn;
                        }
                    } else {
                        return error.SchemeNotDefinedAtTopLevel;
                    };

                    const ObjectEnum = meta.NumEnum(scheme.objects.len);
                    switch (@as(ObjectEnum, @enumFromInt(type_id.name))) {
                        inline else => |object_val| {
                            const object_slot = @intFromEnum(object_val);
                            const object = scheme.objects[object_slot];

                            const Scheme = SchemeFn(define.This);
                            const Obj = for (Scheme.types) |Object| {
                                if (std.mem.eql(Object.name, object.name)) {
                                    break SchemeFn(Object.name);
                                }
                            } else {
                                return error.ObjectNotDefinedAtTopLevel;
                            };

                            const map = &self.slots[scheme_slot][object_slot];
                            const mem = map.getPtr(@bitCast(obj_id));
                            const view = if (mem) |m|
                                read.readObject(
                                    Self,
                                    scheme.name,
                                    object.name,
                                    self,
                                    m.view,
                                )
                            else
                                null;

                            const return_type = @typeInfo(@TypeOf(f)).Fn.return_type.?;
                            if (@typeInfo(return_type) == .ErrorUnion) {
                                return try f(Obj, view, context);
                            } else {
                                return f(Obj, view, context);
                            }
                        },
                    }
                },
            }
        }

        pub fn getBytes(
            self: *Self,
            comptime scheme: []const u8,
            comptime name: []const u8,
            id: u64,
        ) ?[]const u8 {
            const slot = comptime objSlot(scheme, name);
            const map = &self.slots[slot.scheme][slot.type];
            const mem = map.getPtr(id);
            if (mem) |m| {
                return m.view;
            }
            return null;
        }

        pub fn iterator(self: *Self, comptime Obj: type) Iterator(Obj) {
            const slot = comptime objTypeSlot(Obj);
            const map = &self.slots[slot.scheme][slot.type];
            return .{
                .index = self,
                .iter = map.iterator(),
            };
        }

        pub fn View(comptime Obj: type) type {
            return read.ObjectView(Self, Obj.scheme.name, Obj.def.name);
        }

        pub fn Iterator(comptime Obj: type) type {
            return ObjectIterator(Self, Obj.scheme.name, Obj.def.name);
        }

        pub fn Entry(comptime Obj: type) type {
            return Iterator(Obj).Entry;
        }
    };
}

fn ObjectIterator(comptime Index: type, comptime scheme: []const u8, comptime name: []const u8) type {
    return struct {
        index: *Index,
        iter: Index.MemMap.Iterator,

        const Self = @This();

        pub const Entry = struct {
            id: super.ObjectId,
            view: read.ObjectView(Index, scheme, name),
        };

        pub fn next(self: *Self) ?Entry {
            if (self.iter.next()) |entry| {
                const id: super.ObjectId = @bitCast(entry.key_ptr.*);
                const mem = entry.value_ptr;
                const view = read.readObject(Index, scheme, name, self.index, mem.view);
                return .{
                    .id = id,
                    .view = view,
                };
            }
            return null;
        }
    };
}

test "iterator" {
    const Scheme = define.Scheme("test", .{
        define.Object("Obj", .{
            u8,
        }),
    });
    const Obj = Scheme("Obj");

    const Index = ObjectIndex(.{Scheme});
    var index = Index.init(std.testing.allocator);
    defer deinitTestIndex(&index);

    try putObj(&index, 0, 0);
    try putObj(&index, 1, 1);
    try putObj(&index, 2, 2);
    try putObj(&index, 3, 3);

    var iter = index.iterator(Obj);
    var len: usize = 0;
    while (iter.next()) |entry| : (len += 1) {
        try std.testing.expectEqual(entry.id, .{ .scheme = 0, .source = 0, .name = entry.view.v1 });
    }
    try std.testing.expectEqual(@as(usize, 4), len);
}

fn deinitTestIndex(index: anytype) void {
    inline for (index.slots) |slot| {
        inline for (slot) |map| {
            var m = map;
            defer m.deinit();

            var values = m.valueIterator();
            while (values.next()) |mem| {
                std.testing.allocator.free(mem.view);
            }
        }
    }
}

fn putObj(index: anytype, name: u32, value: u8) !void {
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    try serde.serialize(@as(u16, 0), bytes.writer());
    try serde.serialize(value, bytes.writer());

    try index.put(super.Object{
        .type = .{
            .scheme = 0,
            .name = 0,
        },
        .id = .{
            .scheme = 0,
            .source = 0,
            .name = name,
        },
        .mem = .{
            .handle = undefined,
            .view = @constCast(try bytes.toOwnedSlice()),
        },
    });
}
