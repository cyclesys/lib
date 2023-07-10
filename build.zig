const std = @import("std");
const ft = @import("libs/mach-freetype/build.zig");
const vk = @import("build/vulkan.zig");

inline fn libRoot() []const u8 {
    comptime {
        return std.fs.path.dirname(@src().file) orelse ".";
    }
}

pub fn module(b: *std.Build) !*std.Build.Module {
    return b.createModule(.{
        .source_file = .{ .path = libRoot() ++ "src/lib.zig" },
        .dependencies = &.{
            .{
                .name = "vulkan",
                .module = try vk.module(b),
            },
            .{
                .name = "freetype",
                .module = ft.module(b),
            },
            .{
                .name = "harfbuzz",
                .module = ft.harfbuzzModule(b),
            },
            .{
                .name = "known_folders",
                .module = b.createModule(.{
                    .source_file = .{ .path = libRoot() ++ "libs/known-folders/known-folders.zig" },
                }),
            },
        },
    });
}

pub fn link(b: *std.Build, step: *std.Build.CompileStep) void {
    ft.link(b, step, .{ .harfbuzz = .{} });
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/lib.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(lib_tests);
    const run_tests_step = b.step("test", "Run tests");
    run_tests_step.dependOn(&run_tests.step);

    const gen_ucd_exe = b.addExecutable(.{
        .name = "gen_ucd",
        .root_source_file = .{ .path = "build/ucd.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(gen_ucd_exe);

    const gen_ucd_cmd = b.addRunArtifact(gen_ucd_exe);
    gen_ucd_cmd.step.dependOn(b.getInstallStep());
    const gen_ucd_step = b.step("ucd", "Generate ucd.zig");
    gen_ucd_step.dependOn(&gen_ucd_cmd.step);
}
