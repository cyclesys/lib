const std = @import("std");

pub fn ensureCachedFile(allocator: std.mem.Allocator, cache_root: []const u8, name: []const u8, url: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ cache_root, name });
    const file = std.fs.openFileAbsolute(path, .{}) catch |e| {
        switch (e) {
            error.FileNotFound => {
                const result = try std.ChildProcess.exec(.{
                    .allocator = allocator,
                    .argv = &.{ "curl", url, "-o", path },
                });
                allocator.free(result.stdout);
                allocator.free(result.stderr);

                switch (result.term) {
                    .Exited => |code| {
                        if (code != 0) {
                            return error.ExitCodeFailure;
                        }
                    },
                    .Signal, .Stopped, .Unknown => {
                        return error.ProcessTerminated;
                    },
                }

                return path;
            },
            else => {
                return e;
            },
        }
    };
    file.close();
    return path;
}
