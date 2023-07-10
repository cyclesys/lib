const std = @import("std");
const util = @import("util.zig");
const brk = @import("ucd/break.zig");
const brk_test = @import("ucd/break_test.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // this assumes that we're being run through `zig build unicode`.
    const lib_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(lib_root);

    const code_root = try std.fs.path.join(allocator, &.{ lib_root, "src", "ui", "text", "ucd" });
    defer allocator.free(code_root);

    const cache_root = try std.fs.path.join(allocator, &.{ lib_root, "zig-cache" });
    defer allocator.free(cache_root);

    try brk.gen(allocator, code_root, cache_root);
    try brk_test.gen(allocator, code_root, cache_root);
}

// the unicode version the code gen is based on.
const version = [3]u8{ 15, 0, 0 };

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

pub fn ucdFile(comptime name: []const u8) []const u8 {
    comptime {
        var norm_name: [name.len]u8 = undefined;
        @memcpy(&norm_name, name);
        std.mem.replaceScalar(u8, &norm_name, '/', '_');
        return versionStr('_') ++ "-" ++ norm_name;
    }
}

pub fn ucdUrl(comptime name: []const u8) []const u8 {
    comptime {
        return "https://www.unicode.org/Public/" ++ versionStr('.') ++ "/ucd/" ++ name;
    }
}
