const tree = @import("../tree.zig");

pub fn pointer(config: anytype) Pointer(
    tree.ConfigListener(@TypeOf(config)),
    tree.ConfigChild(@TypeOf(config)),
) {
    const PointerNode = Pointer(
        tree.ConfigListener(@TypeOf(config)),
        tree.ConfigChild(@TypeOf(config)),
    );
    return tree.initNode(PointerNode, config);
}

pub fn Pointer(comptime Listener: type, comptime Child: type) type {
    return tree.InputNode(.Pointer, Child, Listener);
}

pub fn key(config: anytype) Key(
    tree.ConfigListener(@TypeOf(config)),
    tree.ConfigChild(@TypeOf(config)),
) {
    const KeyNode = Key(
        tree.ConfigListener(@TypeOf(config)),
        tree.ConfigChild(@TypeOf(config)),
    );
    return tree.initNode(KeyNode, config);
}

pub fn Key(comptime Listener: type, comptime Child: type) type {
    return tree.InputNode(.Key, Child, Listener);
}

pub fn tick(config: anytype) Tick(
    tree.ConfigListener(@TypeOf(config)),
    tree.ConfigChild(@TypeOf(config)),
) {
    const TickNode = Pointer(
        tree.ConfigListener(@TypeOf(config)),
        tree.ConfigChild(@TypeOf(config)),
    );
    return tree.initNode(TickNode, config);
}

pub fn Tick(comptime Listener: type, comptime Child: type) type {
    return tree.InputNode(.Tick, Child, Listener);
}
