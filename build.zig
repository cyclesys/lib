const std = @import("std");
const vkgen = @import("libs/vulkan-zig/generator/index.zig");
const ftgen = @import("libs/mach-freetype/build.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const windows = b.createModule(.{
        .source_file = .{ .path = "windows.zig" },
    });

    const vulkan_sdk_path = b.env_map.get("VULKAN_SDK");
    if (vulkan_sdk_path == null) {
        return error.VulkanSdkNotSet;
    }
    const vulkan_step = vkgen.VkGenerateStep.create(b, vulkan_sdk_path.?);
    const vulkan = vulkan_step.getModule();

    const freetype = ftgen.module(b);
    const harfbuzz = ftgen.harfbuzzModule(b);

    const known_folders = b.createModule(.{
        .source_file = .{ .path = "libs/known-folders/known-folders.zig" },
    });

    const lib_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/lib.zig" },
        .target = target,
        .optimize = optimize,
    });

    lib_tests.addModule("windows", windows);
    lib_tests.addModule("vulkan", vulkan);
    lib_tests.addModule("freetype", freetype);
    lib_tests.addModule("harfbuzz", harfbuzz);
    lib_tests.addModule("known_folders", known_folders);

    const run_tests = b.addRunArtifact(lib_tests);
    const run_tests_step = b.step("test", "Run tests");
    run_tests_step.dependOn(&run_tests.step);
}
