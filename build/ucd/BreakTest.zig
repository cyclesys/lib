const std = @import("std");

allocator: std.mem.Allocator,
cases: []const Case,

pub const Case = struct {
    string: []const u32,
    breaks: []const u32,
};
const Self = @This();

pub fn read(allocator: std.mem.Allocator, file_path: []const u8) !Self {
    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 10_000_000);
    defer allocator.free(bytes);

    var cases = std.ArrayList(Case).init(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        var string = std.ArrayList(u32).init(allocator);
        var breaks = std.ArrayList(u32).init(allocator);
        var iter = std.unicode.Utf8Iterator{ .bytes = line, .i = 0 };
        var unit_start: usize = 0;
        var code_point_start: ?usize = null;
        var code_point: ?u32 = null;
        while (iter.nextCodepointSlice()) |slice| : (unit_start += slice.len) {
            const unit = try std.unicode.utf8Decode(slice);
            switch (unit) {
                '÷' => {
                    if (code_point) |cp| {
                        try breaks.append(cp);
                        code_point = null;
                    }
                },
                '×' => {
                    code_point = null;
                },
                ' ' => {
                    if (code_point_start) |start| {
                        code_point = try std.fmt.parseInt(u32, line[start..unit_start], 16);
                        try string.append(code_point.?);
                        code_point_start = null;
                    }
                },
                '0'...'9', 'A'...'F' => {
                    if (code_point_start == null) {
                        if (code_point != null) {
                            @panic("unconsumed code point");
                        }
                        code_point_start = unit_start;
                    }
                },
                '#' => {
                    break;
                },
                else => {
                    // ignore everything else
                },
            }
        }

        try cases.append(Case{
            .string = try string.toOwnedSlice(),
            .breaks = try breaks.toOwnedSlice(),
        });
    }

    return Self{
        .allocator = allocator,
        .cases = try cases.toOwnedSlice(),
    };
}

pub fn deinit(self: Self) void {
    for (self.cases) |case| {
        self.allocator.free(case.string);
        self.allocator.free(case.breaks);
    }
    self.allocator.free(self.cases);
}
