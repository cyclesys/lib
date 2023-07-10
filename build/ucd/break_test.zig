const std = @import("std");
const util = @import("../util.zig");
const ucd = @import("../ucd.zig");

pub fn gen(allocator: std.mem.Allocator, code_root: []const u8, cache_root: []const u8) !void {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    try writeTestCaseType(&out);

    var expected = std.ArrayList(u8).init(allocator);
    defer expected.deinit();

    try writeTestCases(allocator, "grapheme", &out, &expected, "auxiliary/GraphemeBreakTest.txt", cache_root);
    try writeTestCases(allocator, "word", &out, &expected, "auxiliary/WordBreakTest.txt", cache_root);
    try writeTestCases(allocator, "sentence", &out, &expected, "auxiliary/SentenceBreakTest.txt", cache_root);

    const code_file_path = try std.fs.path.join(allocator, &.{ code_root, "break_test.zig" });
    defer allocator.free(code_file_path);

    const code_file = try std.fs.createFileAbsolute(code_file_path, .{ .truncate = true });
    defer code_file.close();

    try code_file.writeAll(out.items);
}

fn writeTestCaseType(out: *std.ArrayList(u8)) !void {
    try out.appendSlice(
        \\pub const TestCase = struct {
        \\    []const u8,
        \\    []const u32,
        \\};
        \\
    );
}

fn writeTestCases(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    out: *std.ArrayList(u8),
    expected: *std.ArrayList(u8),
    comptime ucd_name: []const u8,
    cache_root: []const u8,
) !void {
    const file_path = try util.ensureCachedFile(
        allocator,
        cache_root,
        comptime ucd.ucdFile(ucd_name),
        comptime ucd.ucdUrl(ucd_name),
    );
    defer allocator.free(file_path);

    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 10_000_000);
    defer allocator.free(bytes);

    try std.fmt.format(out.writer(), "pub const {s}_test_cases = ", .{name});
    try out.appendSlice("[_]TestCase{\n");

    var lines = std.mem.splitScalar(u8, bytes, '\n');

    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        try out.appendSlice("    .{ \"");

        var iter = std.unicode.Utf8Iterator{ .bytes = line, .i = 0 };
        var unit_start: usize = 0;
        var code_point_start: ?usize = null;
        var code_point: ?[]const u8 = null;
        while (iter.nextCodepointSlice()) |slice| : (unit_start += slice.len) {
            const unit = try std.unicode.utf8Decode(slice);
            switch (unit) {
                '÷' => {
                    if (code_point) |point| {
                        if (expected.items.len != 0) {
                            try expected.appendSlice(", ");
                        }
                        try expected.append('\'');
                        try writeUnicodeCodePoint(expected, point);
                        try expected.append('\'');
                        code_point = null;
                    }
                },
                '×' => {
                    code_point = null;
                },
                ' ' => {
                    if (code_point_start) |start| {
                        code_point = line[start..unit_start];
                        try writeUnicodeCodePoint(out, code_point.?);
                        code_point_start = null;
                    }
                },
                '#' => {
                    break;
                },
                '0'...'9', 'A'...'F' => {
                    if (code_point_start == null) {
                        if (code_point != null) {
                            @panic("unconsumed code point");
                        }
                        code_point_start = unit_start;
                    }
                },
                else => {
                    // ignore everything else
                },
            }
        }

        try out.appendSlice("\", &.{ ");
        try out.appendSlice(expected.items);
        expected.clearRetainingCapacity();
        try out.appendSlice(" } },\n");
    }
    try out.appendSlice("};\n");
}

fn writeUnicodeCodePoint(out: *std.ArrayList(u8), code_point: []const u8) !void {
    try out.appendSlice("\\u{");
    try out.appendSlice(code_point);
    try out.append('}');
}
