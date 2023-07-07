const std = @import("std");
const ft = @import("libs/mach-freetype/build.zig");
const vk = @import("build/vulkan.zig");
const uc = @import("build/unicode.zig");

inline fn libRoot() []const u8 {
    comptime {
        return std.fs.path.dirname(@src().file) orelse ".";
    }
}

pub fn module(b: *std.Build) !*std.Build.Module {
    const deps = try makeDependencies(b);
    return b.createModule(.{
        .source_file = .{ .path = libRoot() ++ "src/lib.zig" },
        .dependencies = &.{
            .{
                .name = "vulkan",
                .module = deps.vulkan,
            },
            .{
                .name = "freetype",
                .module = deps.freetype,
            },
            .{
                .name = "harfbuzz",
                .module = deps.harfbuzz,
            },
            .{
                .name = "known_folders",
                .module = deps.known_folders,
            },
        },
    });
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/lib.zig" },
        .target = target,
        .optimize = optimize,
    });

    const deps = try makeDependencies(b);
    lib_tests.addModule("vulkan", deps.vulkan);
    lib_tests.addModule("freetype", deps.freetype);
    lib_tests.addModule("harfbuzz", deps.harfbuzz);
    lib_tests.addModule("known_folders", deps.known_folders);
    ft.link(b, lib_tests, .{ .harfbuzz = .{} });

    const run_tests = b.addRunArtifact(lib_tests);
    const run_tests_step = b.step("test", "Run tests");
    run_tests_step.dependOn(&run_tests.step);

    const gen_uc_exe = b.addExecutable(.{
        .name = "gen_unicode",
        .root_source_file = .{ .path = "build/unicode.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(gen_uc_exe);

    const gen_uc_cmd = b.addRunArtifact(gen_uc_exe);
    gen_uc_cmd.step.dependOn(b.getInstallStep());
    const build_uc_step = b.step("unicode", "Generate unicode.zig");
    build_uc_step.dependOn(&gen_uc_cmd.step);
}

fn makeDependencies(b: *std.Build) !struct {
    vulkan: *std.Build.Module,
    freetype: *std.Build.Module,
    harfbuzz: *std.Build.Module,
    known_folders: *std.Build.Module,
} {
    return .{
        .vulkan = try vk.module(b),
        .freetype = ft.module(b),
        .harfbuzz = ft.harfbuzzModule(b),
        .known_folders = b.createModule(.{
            .source_file = .{ .path = libRoot() ++ "libs/known-folders/known-folders.zig" },
        }),
    };
}
