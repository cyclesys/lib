const std = @import("std");
const vkgen = @import("libs/vulkan-zig/generator/index.zig");
const ftgen = @import("libs/mach-freetype/build.zig");

pub fn build(b: *std.Build) !void {
    const vulkan = try vulkanModule(b);
    const freetype = ftgen.module(b);
    const harfbuzz = ftgen.harfbuzzModule(b);
    const known_folders = b.createModule(.{
        .source_file = .{ .path = "libs/known-folders/known-folders.zig" },
    });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/lib.zig" },
        .target = target,
        .optimize = optimize,
    });

    lib_tests.addModule("vulkan", vulkan);
    lib_tests.addModule("freetype", freetype);
    lib_tests.addModule("harfbuzz", harfbuzz);
    lib_tests.addModule("known_folders", known_folders);
    ftgen.link(b, lib_tests, .{ .harfbuzz = .{} });

    const run_tests = b.addRunArtifact(lib_tests);
    const run_tests_step = b.step("test", "Run tests");
    run_tests_step.dependOn(&run_tests.step);
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
        const Error = std.fs.File.OpenError;
        switch (e) {
            Error.FileNotFound => {
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
