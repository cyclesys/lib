const std = @import("std");
const util = @import("util.zig");

pub fn module(b: *std.Build) !*std.Build.Module {
    const vk_hash = "3dae5d7fbf332970ae0a97d5ab05ae5db93e62f0";
    const vk_file_name = vk_hash ++ "-vk.xml";
    const vk_file_url = "https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/" ++
        vk_hash ++ "/xml/vk.xml";

    const vk_file_path = try util.ensureCachedFile(b.allocator, b.cache_root.path.?, vk_file_name, vk_file_url);

    const vkzig_dep = b.dependency("vulkan_zig", .{
        .registry = vk_file_path,
    });
    return vkzig_dep.module("vulkan-zig");
}
