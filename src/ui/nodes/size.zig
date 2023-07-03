const tree = @import("../tree.zig");

pub fn size(config: anytype) Size(tree.OptionalChild(@TypeOf(config))) {
    const SizeNode = Size(tree.OptionalChild(@TypeOf(config)));
    return tree.initNode(SizeNode, config);
}

pub fn Size(comptime Child: type) type {
    return tree.LayoutNode(.Size, Child, struct {
        width: ?u16 = null,
        height: ?u16 = null,

        const LayoutChild = tree.LayoutChild(Child);
        const Opts = @This();

        pub fn layout(opts: Opts, constraints: tree.Constraints, child: ?LayoutChild) !tree.Size {
            const child_size = if (child) |ch| blk: {
                const ch_size = try ch.layout(.{
                    .width = opts.width orelse constraints.width,
                    .height = opts.height orelse constraints.height,
                });

                ch.offset(.{
                    .x = 0,
                    .y = 0,
                });
                break :blk ch_size;
            } else null;

            return .{
                .width = opts.width orelse if (child_size) |cs| cs.width else 0,
                .height = opts.height orelse if (child_size) |cs| cs.height else 0,
            };
        }
    });
}
