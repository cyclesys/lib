const std = @import("std");
const mach_freetype = @import("mach_freetype");
const vulkan = @import("build/vulkan.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("cycle_lib", .{ .source_file = .{ .path = "src/lib.zig" } });

    const mach_freetype_dep = b.dependency("mach_freetype", .{
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/lib.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib_tests.addModule("freetype", mach_freetype_dep.module("mach-freetype"));
    lib_tests.addModule("harfbuzz", mach_freetype_dep.module("mach-harfbuzz"));
    mach_freetype.linkFreetype(mach_freetype_dep.builder, lib_tests);
    mach_freetype.linkHarfbuzz(mach_freetype_dep.builder, lib_tests);

    lib_tests.addModule("known_folders", b.dependency("known_folders", .{}).module("known-folders"));
    lib_tests.addModule("vulkan", try vulkan.module(b));

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
