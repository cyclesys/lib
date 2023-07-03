const std = @import("std");
const vkgen = @import("libs/vulkan-zig/generator/index.zig");
const ftgen = @import("libs/mach-freetype/build.zig");

const src_root = std.fs.path.dirname(@src().file) orelse ".";

pub fn module(b: *std.Build) !*std.Build.Module {
    const deps = try makeDependencies(b);
    return b.createModule(.{
        .source_file = .{ .path = src_root ++ "src/lib.zig" },
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
    ftgen.link(b, lib_tests, .{ .harfbuzz = .{} });

    const run_tests = b.addRunArtifact(lib_tests);
    const run_tests_step = b.step("test", "Run tests");
    run_tests_step.dependOn(&run_tests.step);
}

fn makeDependencies(b: *std.Build) !struct {
    vulkan: *std.Build.Module,
    freetype: *std.Build.Module,
    harfbuzz: *std.Build.Module,
    known_folders: *std.Build.Module,
} {
    return .{
        .vulkan = try vulkanModule(b),
        .freetype = ftgen.module(b),
        .harfbuzz = ftgen.harfbuzzModule(b),
        .known_folders = b.createModule(.{
            .source_file = .{ .path = "libs/known-folders/known-folders.zig" },
        }),
    };
}

fn vulkanModule(b: *std.Build) !*std.Build.Module {
    const vk_hash = "3dae5d7fbf332970ae0a97d5ab05ae5db93e62f0";
    const vk_url = "https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/" ++
        vk_hash ++ "/xml/vk.xml";
    const vk_file_path = try b.cache_root.join(b.allocator, &.{vk_hash ++ "-vk.xml"});
    try ensureCachedFile(b, vk_file_path, vk_url);

    const vk_step = vkgen.VkGenerateStep.create(b, vk_file_path);
    return vk_step.getModule();
}

fn ensureCachedFile(b: *std.Build, path: []const u8, url: []const u8) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch |e| {
        switch (e) {
            error.FileNotFound => {
                _ = b.exec(&.{ "curl", url, "-o", path });
                return;
            },
            else => {
                return e;
            },
        }
    };
    file.close();
}
