const super = @import("../nodes.zig");
const tree = @import("../tree.zig");

pub const LinearMainAlign = enum {
    end,
    center,
    between,
    evenly,
};

pub const LinearCrossAlign = enum {
    end,
    center,
};

pub const LinearChildInfo = struct {
    weight: ?u16 = null,
    cross_align: ?LinearCrossAlign = null,
};

pub fn linearChild(config: anytype) LinearChild(tree.Child(@TypeOf(config))) {
    const LinearChildNode = LinearChild(tree.Child(@TypeOf(config)));
    return tree.initNode(LinearChildNode, config);
}

pub fn LinearChild(comptime Child: type) type {
    return tree.InfoNode(.LinearChild, Child, LinearChildInfo);
}

pub fn linear(config: anytype) Linear(tree.IterableChildren(@TypeOf(config))) {
    const LinearNode = Linear(tree.IterableChildren(@TypeOf(config)));
    return tree.initNode(LinearNode, config);
}

pub fn Linear(comptime Children: type) type {
    return tree.LayoutNode(.Linear, Children, struct {
        orientation: super.Orientation,
        main_align: ?LinearMainAlign = null,
        cross_align: ?LinearCrossAlign = null,

        const LayoutChildren = tree.IterableLayoutChildren(Children, tree.Size);
        const Opts = @This();

        pub fn layout(opts: Opts, constraints: tree.Constraints, children: LayoutChildren) !tree.Size {
            var remaining_extent: ?u16 = switch (opts.orientation) {
                .vertical => constraints.height,
                .horizontal => constraints.width,
            };
            var max_cross: u16 = 0;
            var total_main: u16 = 0;
            var total_weight: u16 = 0;

            var iter = children.iterator();
            while (iter.next()) |child| {
                if (child.info(LinearChildInfo)) |info| {
                    if (info.weight) |weight| {
                        if (weight == 0) {
                            return error.LinearChildZeroWeight;
                        }

                        total_weight += weight;
                        continue;
                    }
                }
                switch (opts.orientation) {
                    .vertical => {
                        const child_size = try child.layout(.{
                            .width = constraints.width,
                            .height = remaining_extent,
                        });
                        if (remaining_extent != null) {
                            remaining_extent.? -= child_size.height;
                        }
                        max_cross = @max(max_cross, child_size.width);
                        total_main += child_size.height;
                    },
                    .horizontal => {
                        const child_size = try child.layout(.{
                            .width = remaining_extent,
                            .height = constraints.height,
                        });
                        if (remaining_extent != null) {
                            remaining_extent.? -= child_size.width;
                        }
                        max_cross = @max(max_cross, child_size.height);
                        total_main += child_size.width;
                    },
                }
            }

            if (total_weight > 0) {
                var remaining_weight = total_weight;
                if (remaining_extent == null) {
                    return error.LinearUnconstrained;
                }

                iter.reset();
                while (iter.next()) |child| {
                    if (child.info(LinearChildInfo)) |info| {
                        if (info.weight) |weight| {
                            const child_main = weight / remaining_weight * remaining_extent.?;
                            remaining_weight -= weight;

                            switch (opts.orientation) {
                                .vertical => {
                                    const child_size = try child.layout(.{
                                        .width = constraints.width,
                                        .height = child_main,
                                    });
                                    remaining_extent.? -= child_size.height;
                                    max_cross = @max(max_cross, child_size.width);
                                    total_main += child_size.height;
                                },
                                .horizontal => {
                                    const child_size = try child.layout(.{
                                        .width = child_main,
                                        .height = constraints.height,
                                    });
                                    remaining_extent -= child_size.width;
                                    max_cross = @max(max_cross, child_size.height);
                                    total_main += child_size.width;
                                },
                            }

                            if (remaining_extent.? == 0)
                                break;
                        }
                    }
                }
            }

            const spacing_left = if (remaining_extent) |extent| extent else 0;
            var offset_main: u16 = 0;
            for (0..children.len) |i| {
                const child = children.get(i);

                const child_main = if (opts.main_align) |main_align|
                    switch (main_align) {
                        .end => offset_main + spacing_left,
                        .center => offset_main + (spacing_left / 2),
                        .between => if (i > 0)
                            offset_main + (spacing_left / (children.len - 1))
                        else
                            offset_main,
                        .evenly => offset_main + (spacing_left / children.len + 1),
                    }
                else
                    offset_main;

                const child_cross_size = switch (opts.orientation) {
                    .vertical => child.slot.height,
                    .horizontal => child.slot.swidth,
                };
                const child_cross = blk: {
                    var cross_align: ?LinearCrossAlign = opts.cross_align;
                    if (child.info(LinearChildInfo)) |info| {
                        cross_align = info.cross_align orelse cross_align;
                    }

                    if (cross_align) |ca| {
                        break :blk switch (ca) {
                            .end => max_cross - child_cross_size,
                            .center => (max_cross - child_cross_size) / 2,
                        };
                    }

                    break :blk 0;
                };

                switch (opts.orientation) {
                    .vertical => {
                        child.offset(.{
                            .x = child_cross,
                            .y = child_main,
                        });
                        offset_main += child.slot.height;
                    },
                    .horizontal => {
                        child.offset(.{
                            .x = child_main,
                            .y = child_cross,
                        });
                        offset_main += child.slot.width;
                    },
                }
            }

            return switch (opts.orientation) {
                .vertical => .{
                    .width = max_cross,
                    .height = total_main,
                },
                .horizontal => .{
                    .width = total_main,
                    .height = max_cross,
                },
            };
        }
    });
}
