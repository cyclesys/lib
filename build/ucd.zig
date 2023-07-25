const std = @import("std");
const util = @import("util.zig");
const BreakTest = @import("ucd/BreakTest.zig");
const Property = @import("ucd/Property.zig");
const TrieBuilder = @import("ucd/TrieBuilder.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // this assumes that we're being run from where 'build.zig' resides, i.e. through 'zig build ucd'.
    const lib_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(lib_root);

    const gen = try Gen.init(allocator, lib_root);
    defer gen.deinit();

    var emoji_property = try gen.loadProperty("emoji/emoji-data.txt", &.{"Extended_Pictographic"});
    defer emoji_property.deinit();

    try gen.propertyTrie("auxiliary/GraphemeBreakProperty.txt", &emoji_property);
    try gen.propertyTrie("auxiliary/WordBreakProperty.txt", &emoji_property);

    try gen.breakTest("auxiliary/GraphemeBreakTest.txt");
    try gen.breakTest("auxiliary/WordBreakTest.txt");
}

const Gen = struct {
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    code_root: []const u8,

    fn init(allocator: std.mem.Allocator, lib_root: []const u8) !Gen {
        return Gen{
            .allocator = allocator,
            .cache_root = try std.fs.path.join(allocator, &.{ lib_root, "zig-cache" }),
            .code_root = try std.fs.path.join(allocator, &.{ lib_root, "src", "ui", "text", "ucd" }),
        };
    }

    fn deinit(self: Gen) void {
        self.allocator.free(self.code_root);
        self.allocator.free(self.cache_root);
    }

    fn propertyTrie(self: Gen, comptime ucd_path: []const u8, extend: ?*const Property) !void {
        var property = try self.loadProperty(ucd_path, &.{});
        defer property.deinit();

        if (extend) |ext| {
            try property.extend(ext);
        }

        const trie = blk: {
            var builder = try TrieBuilder.init(
                self.allocator,
                @intCast(property.entries.count()),
                @intCast(property.entries.count() + 1),
            );
            defer builder.deinit();

            var iter = property.entries.iterator();
            var value: u32 = 0;
            while (iter.next()) |entry| : (value += 1) {
                const list: *Property.RangeList = entry.value_ptr;
                for (list.items) |range| {
                    try builder.setRange(range.start, range.end, value);
                }
            }

            break :blk try builder.build();
        };
        defer trie.deinit();

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        var formatter = ArrayDataFormatter{ .buf = &buf };
        const keys = property.entries.keys();

        try buf.appendSlice("pub const Value = enum {\n");
        for (keys) |key| {
            try std.fmt.format(buf.writer(), "    {s},\n", .{key});
        }
        try buf.appendSlice("    Any,\n");
        try buf.appendSlice("    Error,\n");
        try buf.appendSlice("};\n");

        try buf.appendSlice("pub const index = [_]u16 {");
        for (trie.index) |val| {
            try formatter.next("0x{X}", val);
        }
        try buf.appendSlice("\n};\n");

        formatter.width = 0;
        try buf.appendSlice("pub const data = [_]Value{");
        for (trie.data) |val| {
            const name = if (val < keys.len)
                keys[val]
            else if (val == keys.len)
                "Any"
            else
                "Error";
            try formatter.next(".{s}", name);
        }
        try buf.appendSlice("\n};\n");

        try std.fmt.format(buf.writer(), "pub const high_start = 0x{X};", .{trie.high_start});

        try self.genCodeFile(ucd_path, buf.items);
    }

    fn loadProperty(self: Gen, comptime ucd_path: []const u8, filters: []const []const u8) !Property {
        const cached_file_path = try self.cachedFilePath(ucd_path);
        defer self.allocator.free(cached_file_path);
        return try Property.read(self.allocator, cached_file_path, filters);
    }

    fn breakTest(self: Gen, comptime ucd_path: []const u8) !void {
        const cached_file_path = try self.cachedFilePath(ucd_path);
        defer self.allocator.free(cached_file_path);

        var break_test = try BreakTest.read(self.allocator, cached_file_path);
        defer break_test.deinit();

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try buf.appendSlice("pub const cases = [_]struct{ []const u8, []const u32 }{\n");
        for (break_test.cases) |case| {
            try buf.appendSlice("    .{ \"");
            for (case.string) |code_point| {
                try writeUnicodeCodePoint(&buf, code_point);
            }
            try buf.appendSlice("\", &.{ ");
            for (case.breaks, 0..) |code_point, i| {
                if (i > 0) {
                    try buf.appendSlice(", ");
                }
                try buf.append('\'');
                try writeUnicodeCodePoint(&buf, code_point);
                try buf.append('\'');
            }
            try buf.appendSlice(" } },\n");
        }
        try buf.appendSlice("};\n");

        try self.genCodeFile(ucd_path, buf.items);
    }

    fn cachedFilePath(self: Gen, comptime ucd_path: []const u8) ![]const u8 {
        const file = comptime blk: {
            var norm_name: [ucd_path.len]u8 = undefined;
            @memcpy(&norm_name, ucd_path);
            std.mem.replaceScalar(u8, &norm_name, '/', '_');
            break :blk versionStr('_') ++ "-" ++ norm_name;
        };

        const url = comptime blk: {
            break :blk "https://www.unicode.org/Public/" ++ versionStr('.') ++ "/ucd/" ++ ucd_path;
        };

        return util.ensureCachedFile(self.allocator, self.cache_root, file, url);
    }

    fn genCodeFile(self: Gen, comptime ucd_path: []const u8, bytes: []const u8) !void {
        const code_file_name = comptime blk: {
            var split = std.mem.splitScalar(u8, ucd_path, '/');
            _ = split.next().?;
            split = std.mem.splitScalar(u8, split.next().?, '.');
            break :blk split.first() ++ ".zig";
        };
        const code_file_path = try std.fs.path.join(self.allocator, &.{ self.code_root, code_file_name });
        defer self.allocator.free(code_file_path);

        const code_file = try std.fs.createFileAbsolute(code_file_path, .{ .truncate = true });
        defer code_file.close();

        try code_file.writeAll(bytes);
    }
};

const ArrayDataFormatter = struct {
    width: usize = 0,
    buf: *std.ArrayList(u8),

    fn next(self: *ArrayDataFormatter, comptime fmt: []const u8, value: anytype) !void {
        const count = std.fmt.count(fmt, .{value});
        if (self.width == 0 or self.width + count + 2 > 120) {
            try self.buf.appendSlice("\n   ");
            self.width = 3;
        }

        try self.buf.append(' ');
        self.width += 1;

        try std.fmt.format(self.buf.writer(), fmt, .{value});
        self.width += count;

        try self.buf.append(',');
        self.width += 1;
    }
};

fn writeUnicodeCodePoint(buf: *std.ArrayList(u8), code_point: u32) !void {
    try buf.appendSlice("\\u{");
    const count = std.fmt.count("{X}", .{code_point});
    if (count < 4) {
        for (0..4 - count) |_| {
            try buf.append('0');
        }
    }
    try std.fmt.format(buf.writer(), "{X}", .{code_point});
    try buf.append('}');
}

fn versionStr(comptime delimiter: u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (version, 0..) |part, i| {
            if (i > 0) {
                result = result ++ .{delimiter};
            }
            const part_str_size = std.fmt.count("{d}", .{part});
            var part_str: [part_str_size]u8 = undefined;
            _ = std.fmt.formatIntBuf(&part_str, part, 10, .lower, .{});
            result = result ++ part_str;
        }
        return result;
    }
}

// the unicode version the code gen is based on.
const version = [3]u8{ 15, 0, 0 };
