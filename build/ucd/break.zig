const std = @import("std");
const util = @import("../util.zig");
const ucd = @import("../ucd.zig");

pub fn gen(allocator: std.mem.Allocator, code_root: []const u8, cache_root: []const u8) !void {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    try writePropertyTableItemType(&out);

    {
        var gen_cats = try loadGeneralCategories(allocator, cache_root);
        defer deinitProperties(allocator, &gen_cats);
        try writePropertyTables(&out, &gen_cats, &.{"N"});
    }

    {
        var derived = try loadProperties(allocator, cache_root, "DerivedCoreProperties.txt", &.{"Alphabetic"});
        defer deinitProperties(allocator, &derived);
        try writePropertyTables(&out, &derived, &.{});
    }

    var emoji_props = try loadProperties(allocator, cache_root, "emoji/emoji-data.txt", &.{"Extended_Pictographic"});
    defer deinitProperties(allocator, &emoji_props);
    {
        var emoji_break_table = BreakTable.init(allocator, "Emoji");
        defer emoji_break_table.deinit();
        try emoji_break_table.addProperties(&emoji_props);
        emoji_break_table.sort();
        try emoji_break_table.write(&out);
    }

    {
        var grapheme_break_table = BreakTable.init(allocator, "Grapheme");
        defer grapheme_break_table.deinit();

        var grapheme_break_props = try loadProperties(allocator, cache_root, "auxiliary/GraphemeBreakProperty.txt", &.{});
        defer deinitProperties(allocator, &grapheme_break_props);

        try grapheme_break_table.addProperties(&grapheme_break_props);
        try grapheme_break_table.addProperties(&emoji_props);
        grapheme_break_table.sort();

        var last: isize = -1;
        for (grapheme_break_table.items.items) |item| {
            if (item.range.begin <= last) {
                return error.OverlappingGraphemeValues;
            }
            last = item.range.begin;
        }

        try grapheme_break_table.write(&out);
    }

    {
        var word_break_table = BreakTable.init(allocator, "Word");
        defer word_break_table.deinit();

        var word_break_props = try loadProperties(allocator, cache_root, "auxiliary/WordBreakProperty.txt", &.{});
        defer deinitProperties(allocator, &word_break_props);

        try word_break_table.addProperties(&word_break_props);
        word_break_table.sort();
        try word_break_table.write(&out);
    }

    {
        var sentence_break_table = BreakTable.init(allocator, "Sentence");
        defer sentence_break_table.deinit();

        var sentence_break_props = try loadProperties(allocator, cache_root, "auxiliary/SentenceBreakProperty.txt", &.{});
        defer deinitProperties(allocator, &sentence_break_props);

        try sentence_break_table.addProperties(&sentence_break_props);
        sentence_break_table.sort();
        try sentence_break_table.write(&out);
    }

    try BreakTable.writeLookupInterval(&out);

    const code_file_path = try std.fs.path.join(allocator, &.{ code_root, "break.zig" });
    defer allocator.free(code_file_path);

    const code_file = try std.fs.createFileAbsolute(code_file_path, .{ .truncate = true });
    defer code_file.close();

    try code_file.writeAll(out.items);
}

fn loadGeneralCategories(allocator: std.mem.Allocator, cache_root: []const u8) !Properties {
    const expand = std.ComptimeStringMap([]const []const u8, .{
        .{ "Lu", &.{ "LC", "L" } },
        .{ "Ll", &.{ "LC", "L" } },
        .{ "Lt", &.{ "LC", "L" } },
        .{ "Lm", &.{"L"} },
        .{ "Lo", &.{"L"} },
        .{ "Mn", &.{"M"} },
        .{ "Mc", &.{"M"} },
        .{ "Me", &.{"M"} },
        .{ "Nd", &.{"N"} },
        .{ "Nl", &.{"N"} },
        .{ "No", &.{"N"} },
        .{ "Pc", &.{"P"} },
        .{ "Pd", &.{"P"} },
        .{ "Ps", &.{"P"} },
        .{ "Pe", &.{"P"} },
        .{ "Pi", &.{"P"} },
        .{ "Pf", &.{"P"} },
        .{ "Po", &.{"P"} },
        .{ "Sm", &.{"S"} },
        .{ "Sc", &.{"S"} },
        .{ "Sk", &.{"S"} },
        .{ "So", &.{"S"} },
        .{ "Zs", &.{"Z"} },
        .{ "Zl", &.{"Z"} },
        .{ "Zp", &.{"Z"} },
        .{ "Cc", &.{"C"} },
        .{ "Cf", &.{"C"} },
        .{ "Cs", &.{"C"} },
        .{ "Co", &.{"C"} },
        .{ "Cn", &.{"C"} },
    });
    return initProperties(allocator, cache_root, "UnicodeData.txt", expand, &.{ "Nd", "Nl", "No" }, struct {
        fn lineInfo(line: []const u8) !LineInfo {
            var props = std.mem.splitScalar(u8, line, ';');
            const code_point = try std.fmt.parseInt(u32, props.next().?, 16);
            const name = props.next().?;
            const category = props.next().?;

            if (std.mem.endsWith(u8, name, ", Last>")) {
                return LineInfo{
                    .property = category,
                    .end = code_point,
                };
            }

            return LineInfo{
                .property = category,
                .begin = code_point,
            };
        }
    }.lineInfo);
}

fn loadProperties(allocator: std.mem.Allocator, cache_root: []const u8, comptime ucd_name: []const u8, filters: []const []const u8) !Properties {
    return initProperties(allocator, cache_root, ucd_name, null, filters, struct {
        fn lineInfo(line: []const u8) !LineInfo {
            var props = std.mem.splitAny(u8, line, ";#");
            const range = std.mem.trim(u8, props.next().?, " ");
            const property = std.mem.trim(u8, props.next().?, " ");

            if (std.mem.indexOfScalar(u8, range, '.')) |i| {
                return LineInfo{
                    .property = property,
                    .begin = try std.fmt.parseInt(u32, range[0..i], 16),
                    .end = try std.fmt.parseInt(u32, range[i + 2 ..], 16),
                };
            }

            return LineInfo{
                .property = property,
                .begin = try std.fmt.parseInt(u32, range, 16),
            };
        }
    }.lineInfo);
}

const CodePointRange = struct {
    begin: u32,
    end: u32,
};
const Properties = std.StringHashMap(std.ArrayList(CodePointRange));

const LineInfo = struct {
    property: []const u8,
    begin: ?u32 = null,
    end: ?u32 = null,
};
const LineInfoFn = fn (line: []const u8) anyerror!LineInfo;

fn initProperties(
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    comptime ucd_name: []const u8,
    expand: anytype,
    filters: []const []const u8,
    comptime lineInfo: LineInfoFn,
) !Properties {
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

    var props = Properties.init(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var range: ?CodePointRange = null;
    var property: []const u8 = undefined;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        const info = try lineInfo(line);
        if (filters.len > 0) {
            inner: for (filters) |f| {
                if (std.mem.eql(u8, f, info.property)) {
                    break :inner;
                }
            } else {
                continue;
            }
        }

        if (range) |*r| {
            if (info.begin) |begin| {
                if (begin != r.end + 1 or !std.mem.eql(u8, property, info.property)) {
                    try addToProperties(allocator, expand, &props, property, r.*);
                    r.begin = begin;
                    r.end = if (info.end) |end| end else r.begin;
                    property = info.property;
                } else {
                    r.end = if (info.end) |end| end else begin;
                }
            } else {
                if (!std.mem.eql(u8, property, info.property)) {
                    @panic("line specified as a continuation of previous property, " ++
                        "but properties are different.");
                }
                r.end = info.end.?;
            }
        } else {
            range = CodePointRange{
                .begin = info.begin.?,
                .end = if (info.end) |end| end else info.begin.?,
            };
            property = info.property;
        }
    }
    try addToProperties(allocator, expand, &props, property, range.?);

    return props;
}

fn deinitProperties(allocator: std.mem.Allocator, props: *Properties) void {
    var iter = props.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit();
    }
    props.deinit();
}

fn addToProperties(
    allocator: std.mem.Allocator,
    expand: anytype,
    props: *Properties,
    property: []const u8,
    range: CodePointRange,
) !void {
    const gop = try props.getOrPut(property);
    if (!gop.found_existing) {
        gop.key_ptr.* = try allocator.dupe(u8, property);
        gop.value_ptr.* = std.ArrayList(CodePointRange).init(allocator);
    }
    try gop.value_ptr.append(range);

    if (@TypeOf(expand) != @TypeOf(null)) {
        if (expand.get(property)) |expansion| {
            for (expansion) |exp_prop| {
                try addToProperties(allocator, null, props, exp_prop, range);
            }
        }
    }
}

fn writePropertyTableItemType(buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice("pub const PropertyTableItem = struct {\n");
    try buf.appendSlice("    u32,\n");
    try buf.appendSlice("    u32,\n");
    try buf.appendSlice("};\n");
}

fn writePropertyTables(buf: *std.ArrayList(u8), properties: *Properties, filters: []const []const u8) !void {
    var iter = properties.iterator();
    while (iter.next()) |entry| {
        const property = entry.key_ptr.*;
        const code_point_ranges = entry.value_ptr.items;

        if (filters.len > 0) {
            for (filters) |f| {
                if (std.mem.eql(u8, f, property)) {
                    break;
                }
            } else {
                continue;
            }
        }

        try buf.appendSlice("pub const ");
        try writeLowerCase(property, buf);
        try buf.appendSlice("_table = [_]PropertyTableItem{\n");

        for (code_point_ranges) |range| {
            try buf.appendSlice("    .{");
            try writeUnicodeCodePoint(buf, range.begin);
            try buf.append(',');
            try writeUnicodeCodePoint(buf, range.end);
            try buf.appendSlice("},\n");
        }
        try buf.appendSlice("};\n");
    }
}

const BreakTable = struct {
    name: []const u8,
    props: PropList,
    items: ItemList,

    const lookup_value_cutoff: u32 = 0x20000;
    const lookup_table_len: u32 = 0x400;
    const lookup_interval = @as(u32, @divFloor(lookup_value_cutoff, lookup_table_len));

    fn writeLookupInterval(buf: *std.ArrayList(u8)) !void {
        try std.fmt.format(buf.writer(), "pub const break_lookup_interval = 0x{x};", .{lookup_interval});
    }

    const PropList = std.ArrayList([]const u8);
    const Item = struct {
        property: usize,
        range: CodePointRange,
    };
    const ItemList = std.ArrayList(Item);

    fn init(allocator: std.mem.Allocator, name: []const u8) BreakTable {
        return BreakTable{
            .name = name,
            .props = PropList.init(allocator),
            .items = ItemList.init(allocator),
        };
    }

    fn deinit(self: BreakTable) void {
        self.props.deinit();
        self.items.deinit();
    }

    fn addProperties(self: *BreakTable, props: *Properties) !void {
        var iter = props.iterator();
        while (iter.next()) |entry| {
            const property = entry.key_ptr.*;
            try self.props.append(property);

            const ranges = entry.value_ptr.*;
            for (ranges.items) |range| {
                try self.items.append(.{
                    .property = self.props.items.len - 1,
                    .range = range,
                });
            }
        }
    }

    fn sort(self: *BreakTable) void {
        std.sort.block(Item, self.items.items, @as(u8, 0), struct {
            fn lessThan(_: u8, lhs: Item, rhs: Item) bool {
                return lhs.range.begin < rhs.range.begin;
            }
        }.lessThan);
    }

    fn write(self: *const BreakTable, buf: *std.ArrayList(u8)) !void {
        try std.fmt.format(buf.writer(), "pub const {s}BreakProperty = enum ", .{self.name});
        try buf.appendSlice("{\n");
        try buf.appendSlice("    Any,\n");
        for (self.props.items) |prop| {
            try std.fmt.format(buf.writer(), "    {s},\n", .{prop});
        }
        try buf.appendSlice("};\n");

        var lookup_table = [_]u32{0} ** lookup_table_len;
        var j: u32 = 0;
        for (0..lookup_table_len) |i| {
            const lookup_from = i * lookup_interval;
            const break_table_len = self.items.items.len;
            while (j < break_table_len) {
                const item = self.items.items[j];
                if (item.range.end >= lookup_from) {
                    break;
                }
                j += 1;
            }
            lookup_table[i] = j;
        }

        try buf.appendSlice("pub const ");
        try writeLowerCase(self.name, buf);
        try buf.appendSlice("_break_lookup = [_]u32{\n");
        for (lookup_table) |val| {
            try std.fmt.format(buf.writer(), "    {d},\n", .{val});
        }
        try buf.appendSlice("};\n");

        try std.fmt.format(buf.writer(), "pub const {s}BreakTableItem = struct ", .{self.name});
        try buf.appendSlice("{\n");
        try std.fmt.format(buf.writer(), "    u32,\n    u32,\n    {s}BreakProperty,\n", .{self.name});
        try buf.appendSlice("};\n");

        try buf.appendSlice("pub const ");
        try writeLowerCase(self.name, buf);
        try std.fmt.format(buf.writer(), "_break_table = [_]{s}BreakTableItem", .{self.name});
        try buf.appendSlice("{\n");
        for (self.items.items) |item| {
            try buf.appendSlice("    .{ ");
            try writeUnicodeCodePoint(buf, item.range.begin);
            try buf.appendSlice(", ");
            try writeUnicodeCodePoint(buf, item.range.end);
            try buf.appendSlice(", .");
            try buf.appendSlice(self.props.items[item.property]);
            try buf.appendSlice(" },\n");
        }
        try buf.appendSlice("};\n");
    }
};

fn writeLowerCase(prop: []const u8, buf: *std.ArrayList(u8)) !void {
    try buf.append(std.ascii.toLower(prop[0]));
    try buf.appendSlice(prop[1..]);
}

fn writeUnicodeCodePoint(out: *std.ArrayList(u8), code_point: u32) !void {
    try out.appendSlice("'\\u{");
    try std.fmt.format(out.writer(), "{x}", .{code_point});
    try out.appendSlice("}'");
}
