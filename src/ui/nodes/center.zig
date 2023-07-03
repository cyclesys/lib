const super = @import("../nodes.zig");
const tree = @import("../tree.zig");

pub fn center(config: anytype) Center(tree.Child(@TypeOf(config))) {
    const CenterNode = Center(tree.Child(@TypeOf(config)));
    return tree.initNode(CenterNode, config);
}

pub fn Center(comptime Child: type) type {
    return tree.LayoutNode(.Center, Child, struct {
        orientation: ?super.Orientation = null,

        const LayoutChild = tree.LayoutChild(Child);
        const Opts = @This();

        pub fn layout(opts: Opts, constraints: tree.Constraints, child: LayoutChild) !tree.Size {
            const child_size = try child.layout(constraints);
            if (opts.orientation) |orientation| {
                switch (orientation) {
                    .vertical => {
                        if (constraints.height) |height| {
                            child.offset(.{
                                .x = 0,
                                .y = (height - child_size.height) / 2,
                            });
                            return .{
                                .width = child_size.width,
                                .height = height,
                            };
                        } else {
                            return error.UnconstrainedCenter;
                        }
                    },
                    .horizontal => {
                        if (constraints.width) |width| {
                            child.offset(.{
                                .x = (width - child_size.width) / 2,
                                .y = 0,
                            });
                            return .{
                                .width = width,
                                .height = child_size.height,
                            };
                        } else {
                            return error.UnconstrainedCenter;
                        }
                    },
                }
            }

            if (constraints.width == null or constraints.height == null) {
                return error.UnconstrainedCenter;
            }
            const width = constraints.width.?;
            const height = constraints.height.?;

            child.offset(.{
                .x = (width - child_size.width) / 2,
                .y = (height - child_size.height) / 2,
            });
            return .{
                .width = width,
                .height = height,
            };
        }
    });
}
