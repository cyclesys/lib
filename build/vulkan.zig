const std = @import("std");
const vkgen = @import("../libs/vulkan-zig/generator/index.zig");
const util = @import("util.zig");

pub fn module(b: *std.Build) !*std.Build.Module {
    const vk_hash = "3dae5d7fbf332970ae0a97d5ab05ae5db93e62f0";
    const vk_file_name = vk_hash ++ "-vk.xml";
    const vk_file_url = "https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/" ++
        vk_hash ++ "/xml/vk.xml";

    const vk_file_path = try util.ensureCachedFile(b.allocator, b.cache_root.path.?, vk_file_name, vk_file_url);
    defer b.allocator.free(vk_file_path);

    const vk_step = vkgen.VkGenerateStep.create(b, vk_file_path);
    return vk_step.getModule();
}
