const super = @import("../nodes.zig");
const tree = @import("../tree.zig");

pub fn fill(config: anytype) Fill(tree.OptionalChild(@TypeOf(config))) {
    const FillNode = Fill(tree.OptionalChild(@TypeOf(config)));
    return tree.initNode(FillNode, config);
}

pub fn Fill(comptime Child: type) type {
    return tree.LayoutNode(.Fill, Child, struct {
        orientation: ?super.Orientation = null,

        const LayoutChild = tree.LayoutChild(Child);
        const Opts = @This();

        pub fn layout(opts: Opts, constraints: tree.Constraints, child: ?LayoutChild) !tree.Size {
            const child_size = if (child) |ch| blk: {
                const size = try ch.layout(constraints);
                ch.offset(.{
                    .x = 0,
                    .y = 0,
                });
                break :blk size;
            } else null;

            if (opts.orientation) |orientation| {
                switch (orientation) {
                    .vertical => {
                        if (constraints.height) |height| {
                            return .{
                                .width = if (child_size) |cs| cs.width else 0,
                                .height = height,
                            };
                        } else {
                            return error.UnconstrainedFill;
                        }
                    },
                    .horizontal => {
                        if (constraints.width) |width| {
                            return .{
                                .width = width,
                                .height = if (child_size) |cs| cs.height else 0,
                            };
                        } else {
                            return error.UnconstrainedFill;
                        }
                    },
                }
            }

            if (constraints.width == null or constraints.height == null) {
                return error.UnconstrainedFill;
            }

            return .{
                .width = constraints.width.?,
                .height = constraints.height.?,
            };
        }
    });
}
