const std = @import("std");
const meta = @import("meta.zig");

pub const Tree = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {};
};

pub const Constraints = struct {
    width: ?u16 = null,
    height: ?u126 = null,
};

pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Offset = struct {
    x: u16,
    y: u16,

    pub const zero = Offset{
        .x = 0,
        .y = 0,
    };

    pub fn add(self: *Offset, other: Offset) void {
        self.x += other.x;
        self.y += other.y;
    }
};

const NodeKind = enum {
    Build,
    Input,
    Layout,
    Info,
    Render,
};

fn assertIsNode(comptime Type: type) void {
    if (!isNode(Type)) {
        @compileError("");
    }
}

fn isNode(comptime Type: type) bool {
    return @hasDecl(Type, "kind") and @TypeOf(Type.kind) == NodeKind;
}

pub fn BuildNode(comptime node_id: anytype, comptime ChildBuilder: type) type {
    return struct {
        opts: Builder,

        pub const kind = NodeKind.Build;
        pub const id = node_id;
        pub const Builder = ChildBuilder;
    };
}

pub fn InputNode(comptime node_id: anytype, comptime ChildNode: type, comptime InputListener: type) type {
    return struct {
        listener: Listener,
        child: Child,

        pub const kind = NodeKind.Input;
        pub const id = node_id;
        pub const Child = ChildNode;
        pub const Listener = InputListener;
    };
}

pub fn LayoutNode(comptime node_id: anytype, comptime ChildNodes: type, comptime ChildrenLayout: type) type {
    return struct {
        opts: Layout,
        child: Child,

        pub const kind = NodeKind.Layout;
        pub const id = node_id;
        pub const Child = ChildNodes;
        pub const Layout = ChildrenLayout;
    };
}

pub fn InfoNode(comptime node_id: anytype, comptime ChildNode: type, comptime ChildInfo: type) type {
    return struct {
        info: Info,
        child: Child,

        pub const kind = NodeKind.Info;
        pub const id = node_id;
        pub const Child = ChildNode;
        pub const Info = ChildInfo;
    };
}

pub fn RenderNode(comptime node_id: anytype, comptime ChildNode: type, comptime RenderInfo: type) type {
    return struct {
        info: Info,
        child: Child,

        pub const kind = NodeKind.Render;
        pub const id = node_id;
        pub const Child = ChildNode;
        pub const Info = RenderInfo;
    };
}

pub fn NodeType(comptime Type: type) type {
    assertIsNode(Type);
    return Type;
}

pub fn OptionalNodeType(comptime Type: type) type {
    const Node = if (@typeInfo((Type) == .Optional))
        std.meta.Child(Type)
    else
        Type;
    assertIsNode(Node);
    return ?Node;
}

pub fn ChildType(comptime Config: type) type {
    if (!@hasField(Config, "child")) {
        @compileError("");
    }
    const FieldType = std.meta.FieldType(Config, .child);
    assertIsNode(FieldType);
    return FieldType;
}

pub fn OptionalChildType(comptime Config: type) type {
    if (@hasField(Config, "child")) {
        const Type = std.meta.FieldType(Config, .child);
        if (@typeInfo(Type) == .Optional) {
            const OptType = std.meta.Child(Type);
            assertIsNode(OptType);
            return ?OptType;
        }
        assertIsNode(Type);
        return Type;
    }
    return void;
}

pub fn SlottedChildrenType(comptime Slots: type, comptime Config: type) type {
    const info = @typeInfo(Slots).Struct;
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    for (info.fields, 0..) |field, i| {
        const Type = if (@hasField(Config, field.name)) blk: {
            const ConfigType = meta.FieldType(Config, field.name);
            if (@typeInfo(ConfigType) == .Optional) {
                if (@typeInfo(field.type != .Optional)) {
                    @compileError("");
                }
                const OptType = std.meta.Child(ConfigType);
                assertIsNode(OptType);
                break :blk ?OptType;
            }
            assertIsNode(ConfigType);
            break :blk ConfigType;
        } else if (@typeInfo(field.type) == .Optional)
            void
        else
            @compileError("");

        fields[i] = .{
            .name = field.name,
            .type = Type,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(Type),
        };
    }

    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

pub fn IterableChildrenType(comptime Config: type) type {
    if (!@hasField(Config, "children")) {
        @compileError("");
    }

    const Children = std.meta.FieldType(Config, .children);
    const info = @typeInfo(Children).Struct;
    if (!info.is_tuple) {
        @compileError("");
    }

    for (info.fields) |field| {
        assertIsNode(field.type);
    }

    return Children;
}

pub fn ListenerType(comptime Config: type) type {
    return std.meta.FieldType(Config, .listener);
}

pub fn initNode(comptime Node: type, config: anytype) Node {
    switch (Node.kind) {
        .Build => {
            return Node{
                .opts = nodeOpts(Node.Opts, config),
            };
        },
        .Layout => {
            return Node{
                .opts = nodeOpts(Node.Opts, config),
                .child = blk: {
                    const Config = @TypeOf(config);
                    if (@hasField(Config, "child")) {
                        break :blk config.child;
                    }

                    if (@hasField(Config, "children")) {
                        break :blk config.children;
                    }
                },
            };
        },
        .Input => {
            return Node{
                .listener = config.listener,
                .child = config.child,
            };
        },
        .Info, .Render => {
            return Node{
                .info = nodeOpts(Node.Info, config),
                .child = if (Node.Child == void)
                    undefined
                else
                    config.child,
            };
        },
    }
}

fn nodeOpts(comptime Opts: type, config: anytype) Opts {
    const info = @typeInfo(Opts).Struct;
    if (info.fields.len == 0) {
        return .{};
    }

    const Config = @TypeOf(config);
    var result: Opts = undefined;
    inline for (info.fields) |field| {
        if (@hasField(Config, field.name)) {
            @field(result, field.name) = @field(config, field.name);
        } else if (field.default_value) |default_value| {
            @field(result, field.name) = @as(*const field.type, @ptrCast(default_value)).*;
        } else {
            @compileError("");
        }
    }
    return result;
}

pub fn SlottedLayoutChildren(comptime Slots: type, comptime ChildNodes: type) type {
    const info = @typeInfo(Slots).Struct;
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    for (fields, 0..) |field, i| {
        const ChildNode = meta.FieldType(ChildNodes, field.name);
        const FieldType = if (ChildNode == void)
            ?LayoutChild(void)
        else if (@typeInfo(ChildNode) == .Optional)
            ?LayoutChild(std.meta.Child(ChildNode))
        else if (@typeInfo(field.type) == .Optional)
            ?LayoutChild(ChildNode)
        else
            LayoutChild(ChildNode);
        fields[i] = .{
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
            .fields = &fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

pub fn IterableLayoutChildren(comptime ChildNodes: type, comptime Slot: type) type {
    return struct {
        comptime len: usize = children_len,
        states: *States,
        slots: *Slots,

        const children_len = @typeInfo(ChildNodes).Struct.fields.len;
        pub const Iterator = struct {
            states: *States,
            slots: *Slots,
            idx: usize = 0,

            const IteratorSelf = @This();

            pub fn next(self: *IteratorSelf) ?Child {
                if (self.idx >= children_len) {
                    return null;
                }

                const child = Child{
                    .states = self.states,
                    .slot = &self.slots[self.idx],
                    .tag = @enumFromInt(self.idx),
                };
                self.idx += 1;
                return child;
            }

            pub fn reset(self: *Self) void {
                self.idx = 0;
            }
        };
        pub const Child = struct {
            states: *States,
            slot: *Slot,
            tag: Tag,

            pub const Tag = meta.NumEnum(children_len);

            pub fn info(self: Child, comptime Info: type) ?Info {
                switch (self.tag) {
                    inline else => |tag| {
                        return @field(self.inner, @tagName(tag)).info(Info);
                    },
                }
            }

            pub fn layout(self: Child, constraints: Constraints) !Size {
                switch (self.tag) {
                    inline else => |tag| {
                        const size = try @field(self.inner, @tagName(tag)).layout(constraints);
                        if (Slot == Size) {
                            self.slot.* = size;
                        }
                        return size;
                    },
                }
            }

            pub fn offset(self: Child, by: Offset) void {
                switch (self.tag) {
                    inline else => |tag| {
                        @field(self.inner, @tagName(tag)).offset(by);
                    },
                }
            }
        };
        pub const States = blk: {
            const info = @typeInfo(ChildNodes);
            var types: [info.fields.len]type = undefined;
            for (info.fields, 0..) |field, i| {
                types[i] = LayoutChild(field.type);
            }
            break :blk meta.Tuple(types);
        };
        pub const Slots = if (Slot == void) void else [children_len]Slot;
        const Self = @This();

        pub fn get(self: Self, idx: usize) Child {
            if (idx >= children_len) {
                @panic("index out of bounds");
            }
            return Child{
                .states = self.states,
                .slot = &self.slots[idx],
                .tag = @enumFromInt(idx),
            };
        }

        pub fn iterator(self: Self) Iterator {
            return Iterator{
                .states = self.states,
                .slots = self.slots,
            };
        }
    };
}

pub fn LayoutChild(comptime Child: type) type {
    return struct {
        allocator: std.mem.Allocator,
        node: Node,
        state: State,

        const Node = blk: {
            if (Child == void) {
                break :blk void;
            }

            const Type = if (@typeInfo(Child) == .Optional)
                std.meta.Child(Child)
            else
                Child;
            assertIsNode(Type);
            break :blk Type;
        };
        const State = if (Node == void) void else BuildState(Node);
        const Self = @This();

        pub fn info(self: Self, comptime Info: type) ?Info {
            if (Node != void and Node.kind == .Info and Node.Info == Info) {
                return self.node.info;
            }
            return null;
        }

        pub fn layout(self: Self, constraints: Constraints) !Size {
            if (Node != void) {
                return if (Node.kind == .Info)
                    try build(self.allocator, self.node.child, self.state, constraints)
                else
                    try build(self.allocator, self.node, self.state, constraints);
            }
        }

        pub fn offset(self: Self, by: Offset) void {
            if (Node != void) {
                walkTree(InputTree(Node), self.state.input, by, offsetNode);
                walkTree(RenderTree(Node), self.state.render, by, offsetNode);
            }
        }
    };
}

fn BuildTree(Node: type) type {
    return switch (Node.kind) {
        .Build => BuildTreeNode(Node),
        .Input => BuildTree(Node.Child),
        .Layout => LayoutTree(Node, BuildTree),
        .Info, .Render => if (Node.Child == void)
            void
        else
            BuildTree(Node.Child),
    };
}

fn BuildTreeNode(comptime Node: type) type {
    return struct {
        state: State,
        child: Child,

        pub const State = Node.Builder.State;
        pub const Child = BuildTree(BuildChild(Node));
        pub const Id = Node.id;
        const Self = @This();

        pub fn deinit(self: *Self) void {
            if (Child != void) {
                walkTree(Child, &self.child, null, deinitNode);
            }
            if (@hasDecl(State, "deinit")) {
                self.state.deinit();
            }
        }
    };
}

fn deinitNode(child: anytype, _: @Type(.Null)) void {
    child.deinit();
}

fn InputTree(comptime Node: type) type {
    return switch (Node.kind) {
        .Build => InputTree(BuildChild(Node)),
        .Input => InputTreeNode(Node),
        .Layout => LayoutTree(Node, InputTree),
        .Info, .Render => if (Node.Child == void)
            void
        else
            InputTree(Node.Child),
    };
}

fn InputTreeNode(comptime Node: type) type {
    return struct {
        size: Size,
        offset: Offset,
        listener: Node.Listener,
        child: Child,

        pub const id = Node.id;
        const Child = InputTree(Node.Child);
        const Self = @This();

        pub fn offset(self: *Self, by: Offset) void {
            self.offset.add(by);
            if (Child != void) {
                walkTree(Child, &self.child, by, offsetNode);
            }
        }
    };
}

fn RenderTree(comptime Node: type) type {
    return switch (Node.kind) {
        .Build => RenderTree(BuildChild(Node)),
        .Input => RenderTree(Node.Child),
        .Layout => LayoutTree(Node, RenderTree),
        .Info => RenderTree(Node.Child),
        .Render => RenderTreeNode(Node),
    };
}

fn RenderTreeNode(comptime Node: type) type {
    return struct {
        size: Size,
        offset: Offset,
        info: Node.Info,
        child: Child,

        pub const id = Node.id;
        const Child = if (Node.Child == void) void else RenderTree(Node.Child);
        const Self = @This();

        pub fn offset(self: *Self, by: Offset) void {
            self.offset.add(by);
            if (Child != void) {
                walkTree(Child, &self.child, by, offsetNode);
            }
        }
    };
}

fn offsetNode(child: anytype, by: Offset) void {
    child.offset(by);
}

fn BuildChild(comptime Node: type) type {
    const ReturnType = @typeInfo(@TypeOf(Node.Builder.build)).Fn.return_type.?;
    const Type = @typeInfo(ReturnType).ErrorUnion.payload;
    assertIsNode(Type);
    return Type;
}

fn LayoutTree(
    comptime Node: type,
    comptime ChildTree: fn (comptime Node: type) type,
) type {
    const Child = Node.Child;
    if (Child == void) {
        return void;
    }

    if (@typeInfo(Child) == .Optional) {
        const Type = ChildTree(std.meta.Child(Child));
        if (Type == void) {
            return void;
        }
        return ?Type;
    }

    if (isNode(Child)) {
        return ChildTree(Child);
    }

    const info = @typeInfo(Child);
    var types: [info.fields.len]type = undefined;
    var len = 0;
    for (info.fields) |field| {
        if (info.is_tuple) {
            const Type = ChildTree(field.type);
            if (Type != void) {
                types[len] = Type;
                len += 1;
            }
        } else if (field.type != void) {
            if (@typeInfo(field.type) == .Optional) {
                const Type = ChildTree(std.meta.Child(field.type));
                if (Type != void) {
                    types[len] = ?Type;
                    len += 1;
                }
            } else {
                const Type = ChildTree(field.type);
                if (Type != void) {
                    types[len] = Type;
                    len += 1;
                }
            }
        }
    }

    if (len == 0) {
        return void;
    }

    return meta.Tuple(types[0..len]);
}

fn walkTree(comptime T: type, t: *T, args: anytype, f: fn (anytype, @TypeOf(args)) void) void {
    if (std.meta.trait.isTuple(T)) {
        inline for (t) |*node| {
            f(node, args);
        }
    } else if (@typeInfo(T) == .Optional) {
        if (t.*) |*node| {
            f(node, args);
        }
    } else {
        f(t, args);
    }
}

fn TreeState(comptime Node: type) type {
    return struct {
        build: BuildTree(Node),
        input: InputTree(Node),

        const Self = @This();

        fn tree(self: *Self) Tree {
            return Tree{
                .ptr = @ptrCast(self),
                .vtable = &.{},
            };
        }
    };
}

fn BuildState(comptime Node: type) type {
    return struct {
        first_build: bool,
        build: *BuildTree(Node),
        input: *InputTree(Node),
        render: *RenderTree(Node),
    };
}

pub fn render(
    allocator: std.mem.Allocator,
    tree: ?Tree,
    constraints: Constraints,
    node: anytype,
) !Tree {
    const Node = @TypeOf(node);
    const State = TreeState(Node);
    var state: *State = undefined;
    var first_build: bool = undefined;
    if (tree) |t| {
        state = @ptrCast(t.ptr);
        first_build = false;
    } else {
        state = try allocator.create(State);
        first_build = true;
    }

    var render_state: RenderTree(Node) = undefined;
    const size = try build(
        allocator,
        node,
        .{
            .first_build = first_build,
            .build = &state.build,
            .input = &state.input,
            .render = &render_state,
        },
        constraints,
    );
    _ = size;

    return state.tree();
}

fn build(
    allocator: std.mem.Allocator,
    node: anytype,
    state: BuildState(@TypeOf(node)),
    constraints: Constraints,
) !Size {
    const Node = @TypeOf(node);
    return switch (Node.kind) {
        .Build => buildBuild(allocator, node, state, constraints),
        .Input => buildInput(allocator, node, state, constraints),
        .Layout => buildLayout(allocator, node, state, constraints),
        .Render => buildRender(allocator, node, state, constraints),
        else => @compileError("expected a build, input, layout, or render node here."),
    };
}

fn buildBuild(
    allocator: std.mem.Allocator,
    node: anytype,
    state: BuildState(@TypeOf(node)),
    constraints: Constraints,
) !Size {
    const Node = @TypeOf(node);
    const Builder = Node.Builder;
    const State = Builder.State;
    const info = @typeInfo(@TypeOf(Node.Builder.build)).Fn;
    const ChildNode = BuildChild(Node);

    if (state.first_build) {
        const init_info = @typeInfo(@TypeOf(State.init)).Fn;
        if (init_info.params.len == 1) {
            try State.init(&state.build.state);
        } else if (init_info.params.len == 2) {
            if (init_info.params[1].type.? == std.mem.Allocator) {
                try State.init(&state.build.state, allocator);
            } else {
                try State.init(&state.build.state, node.opts);
            }
        } else {
            try State.init(&state.build.state, node.opts, allocator);
        }
    } else if (@hasDecl(State, "update")) {
        try State.update(&state.build.state, node.opts);
    }

    var child: ChildNode = undefined;
    if (info.params.len == 1) {
        child = try Builder.build(&state.build.state);
    } else if (info.params.len == 2) {
        if (info.params[1].type.? == Constraints) {
            child = try Builder.build(&state.build.state, constraints);
        } else {
            child = try Builder.build(&state.build.state, node.opts);
        }
    } else {
        child = try Builder.build(&state.build.state, node.opts, constraints);
    }

    var child_build: *BuildTree(ChildNode) = undefined;
    if (ChildNode != void) {
        child_build = &state.build.child;
    }
    const size = try build(
        allocator,
        child,
        .{
            .first_build = state.first_build,
            .build = child_build,
            .input = state.input,
            .render = state.render,
        },
        constraints,
    );

    return size;
}

fn buildInput(
    allocator: std.mem.Allocator,
    node: anytype,
    state: BuildState(@TypeOf(node)),
    constraints: Constraints,
) !Size {
    const ChildNode = @TypeOf(node.child);
    var child_input: *InputTree(ChildNode) = undefined;
    if (InputTree(ChildNode) != void) {
        child_input = &state.input.child;
    }

    const size = try build(
        allocator,
        node.child,
        .{
            .build = state.build,
            .input = child_input,
            .render = state.render,
        },
        constraints,
    );

    state.input.size = size;
    state.input.offset = Offset.zero;
    state.input.listener = node.listener;

    return size;
}

fn buildLayout(
    allocator: std.mem.Allocator,
    node: anytype,
    state: BuildState(@TypeOf(node)),
    constraints: Constraints,
) !Size {
    const Node = @TypeOf(node);
    const Child = Node.Child;
    const Layout = Node.Layout;
    const has_opts = std.meta.fields(Node.Layout).len == 0;
    const params = @typeInfo(@TypeOf(Layout.layout)).Fn.params;
    const ChildParam = if (has_opts)
        params[2].type.?
    else
        params[1].type.?;

    const info = @typeInfo(Child);
    if (info == .Optional or isNode(Child)) {
        if (info == .Optional and @typeInfo(ChildParam) != .Optional) {
            @compileError("");
        }

        const ChildNode = if (info == .Optional) std.meta.Child(Child) else Child;
        if (info == .Optional and node.child == null) {
            if (BuildTree(ChildNode) != void) {
                if (!state.first_build and state.build.* != null) {
                    state.build.deinit();
                    state.build.* = null;
                }
                state.build.* = null;
            }
            if (InputTree(ChildNode) != void) {
                state.input.* = null;
            }
            if (RenderTree(ChildNode) != void) {
                state.render.* = null;
            }

            return if (has_opts)
                try Layout.layout(node.opts, constraints, null)
            else
                try Layout.layout(constraints, null);
        } else {
            var child_build: *BuildTree(ChildNode) = undefined;
            var first_build = state.first_build;
            if (BuildTree(ChildNode) != void) {
                if (info == .Optional) {
                    child_build = &state.build.*.?;
                    if (!first_build and state.build.* == null) {
                        first_build = true;
                    }
                } else {
                    child_build = state.build;
                }
            }

            var child_input: *InputTree(ChildNode) = undefined;
            if (InputTree(ChildNode) != void) {
                child_input = if (info == .Optional)
                    &state.input.*.?
                else
                    state.input;
            }

            var child_render: *RenderTree(ChildNode) = undefined;
            if (RenderTree(ChildNode) != void) {
                child_render = if (info == .Optional)
                    &state.render.*.?
                else
                    state.render;
            }

            const child = .{
                .allocator = allocator,
                .node = if (info == .Optional) node.child.? else node.child,
                .state = .{
                    .first_build = first_build,
                    .build = child_build,
                    .input = child_input,
                    .render = child_render,
                },
            };

            return if (has_opts)
                try Layout.layout(node.opts, constraints, child)
            else
                try Layout.layout(constraints, child);
        }
    } else if (info.is_tuple) {
        var states: ChildParam.States = undefined;
        comptime var build_idx = 0;
        comptime var input_idx = 0;
        comptime var render_idx = 0;
        inline for (info.fields) |field| {
            const child_node = @field(node.child, field.name);
            const ChildNode = @TypeOf(child_node);

            var child_build: *BuildTree(ChildNode) = undefined;
            if (BuildTree(ChildNode) != void) {
                child_build = &state.build[build_idx];
                build_idx += 1;
            }

            var child_input: *InputTree(ChildNode) = undefined;
            if (InputTree(ChildNode) != void) {
                child_input = &state.input[input_idx];
                input_idx += 1;
            }

            var child_render: *RenderTree(ChildNode) = undefined;
            if (RenderTree(ChildNode) != void) {
                child_render = &state.render[render_idx];
                render_idx += 1;
            }
            @field(states, field.name) = .{
                .allocator = allocator,
                .node = child_node,
                .state = .{
                    .build = child_build,
                    .input = child_input,
                    .render = child_render,
                },
            };
        }

        var slots: ChildParam.Slots = undefined;

        return if (has_opts)
            try Layout.layout(node.opts, constraints, ChildParam{ .states = &states, .slots = &slots })
        else
            try Layout.layout(constraints, ChildParam{ .states = &states, .slots = &slots });
    } else {
        var children: ChildParam = undefined;
        comptime var build_idx = 0;
        comptime var input_idx = 0;
        comptime var render_idx = 0;
        inline for (info.fields) |field| {
            if (field.type == void) {
                @field(children, field.name) = null;
                continue;
            }

            const ChildNode = if (@typeInfo(field.type) == .Optional)
                std.meta.Child(field.type)
            else
                field.type;

            var child_build: *BuildTree(ChildNode) = undefined;
            if (BuildTree(ChildNode) != void) {
                child_build = &state.build[build_idx];
                build_idx += 1;
            }

            var child_input: *InputTree(ChildNode) = undefined;
            if (InputTree(ChildNode) != void) {
                child_input = &state.input[input_idx];
                input_idx += 1;
            }

            var child_render: *RenderTree(ChildNode) = undefined;
            if (RenderTree(ChildNode) != void) {
                child_render = &state.render[render_idx];
                render_idx += 1;
            }

            var child_state = .{
                .first_build = state.first_build,
                .build = child_build,
                .input = child_input,
                .render = child_render,
            };

            if (@typeInfo(field.type) == .Optional) {
                if (@field(node.child, field.name)) |child_node| {
                    if (!state.first_build and BuildTree(ChildNode) != void and state.build[build_idx] == null) {
                        child_state.first_build = true;
                    }
                    @field(children, field.name) = .{
                        .allocator = allocator,
                        .node = child_node,
                        .state = child_state,
                    };
                } else {
                    if (!state.first_build and BuildTree(ChildNode) != void and state.build[build_idx] != null) {
                        state.build[build_idx].deinit();
                        state.build[build_idx] = null;
                    }
                    @field(children, field.name) = null;
                }
            } else {
                @field(children, field.name) = .{
                    .allocator = allocator,
                    .node = @field(node.child, field.name),
                    .state = child_state,
                };
            }
        }

        return if (has_opts)
            try Layout.layout(node.opts, constraints, children)
        else
            try Layout.layout(constraints, children);
    }
}

fn buildRender(
    allocator: std.mem.Allocator,
    node: anytype,
    state: BuildState(@TypeOf(node)),
    constraints: Constraints,
) !Size {
    const Node = @TypeOf(node);
    if (Node.Id == .Text) {
        @compileError("todo!");
    } else {
        const ChildNode = @TypeOf(node.child);
        var child_render: *RenderTree(ChildNode) = undefined;
        if (RenderTree(ChildNode) != void) {
            child_render = &state.render.child;
        }

        const size = try build(
            allocator,
            node.child,
            .{
                .build = state.build,
                .input = state.input,
                .render = child_render,
            },
            constraints,
        );

        state.render.size = size;
        state.render.offset = Offset.zero;
        state.render.info = node.info;

        return size;
    }
}
