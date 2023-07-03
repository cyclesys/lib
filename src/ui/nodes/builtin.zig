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

pub fn rect(config: anytype) Rect(tree.Child(@TypeOf(config))) {
    const RectNode = Rect(tree.Child(@TypeOf(config)));
    return tree.initNode(RectNode, config);
}

pub fn Rect(comptime Child: type) type {
    return tree.RenderNode(.Rect, Child, struct {
        radius: ?struct {
            top_left: ?u16 = null,
            top_right: ?u16 = null,
            bottom_left: ?u16 = null,
            bottom_right: ?u16 = null,
        } = null,
    });
}

pub fn oval(config: anytype) Oval(tree.Child(@TypeOf(config))) {
    const OvalNode = Oval(tree.Child(@TypeOf(config)));
    return tree.initNode(OvalNode, config);
}

pub fn Oval(comptime Child: type) type {
    return tree.RenderNode(.Oval, Child, struct {});
}

pub fn text(config: anytype) Text {
    return tree.initNode(Text, config);
}

pub const Text = tree.RenderNode(.Text, void, struct {
    text: []const u8,
});
