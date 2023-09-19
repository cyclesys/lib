const vk = @import("vk");
const win = @import("../../windows.zig");
const fns = @import("fns.zig");
const Target = @import("Target.zig");

targets: [2]Target,
event: win.HANDLE,
mutex: win.HANDLE,

pub const Error = error{
    SwapchainInvalid,
};
const Self = @This();

pub fn init(targets: [2]Target, event: win.HANDLE, mutex: win.HANDLE) Self {
    return Self{
        .targets = targets,
        .event = event,
        .mutex = mutex,
    };
}

pub fn create(
    device_fns: anytype,
    device: vk.Device,
    memory_type_index: u32,
    format: vk.Format,
    queue_family_index: u32,
    width: u32,
    height: u32,
) Self {
    const targets = [_]Target{
        try Target.create(
            device_fns,
            device,
            memory_type_index,
            format,
            queue_family_index,
            width,
            height,
        ),
        try Target.create(
            device_fns,
            device,
            memory_type_index,
            format,
            queue_family_index,
            width,
            height,
        ),
    };
    const event = win.CreateEventW(
        null,
        win.TRUE,
        win.FALSE,
        null,
    );
    const mutex = win.CreateMutexW(
        null,
        win.FALSE,
        null,
    );
    return Self{
        .targets = targets,
        .event = event,
        .mutex = mutex,
    };
}

pub fn target(self: *Self) !*Target {
    const signaled = switch (win.WaitForSingleObject(self.event, 0)) {
        win.WAIT_OBJECT_0 => true,
        win.WAIT_TIMEOUT => false,
        win.WAIT_FAILED, win.WAIT_ABANDONED => return error.SwapchainInvalid,
        else => unreachable,
    };
    return &self.targets[@intFromBool(signaled)];
}

pub fn swap(self: *Self) !void {
    switch (win.WaitForSingleObject(self.mutex, win.INFINITE)) {
        win.WAIT_OBJECT_0 => {},
        win.WAIT_TIMEOUT, win.WAIT_FAILED, win.WAIT_ABANDONED => return error.SwapchainInvalid,
    }

    switch (win.WaitForSingleObject(self.event, 0)) {
        win.WAIT_OBJECT_0 => {
            if (win.ResetEvent(self.event) == win.FALSE) {
                return error.SwapchainInvalid;
            }
        },
        win.WAIT_TIMEOUT => {
            if (win.SetEvent(self.event) == win.FALSE) {
                return error.SwapchainInvalid;
            }
        },
        win.WAIT_FAILED, win.WAIT_ABANDONED => return error.SwapchainInvalid,
        else => unreachable,
    }

    if (win.ReleaseMutex(self.mutex) == win.FALSE) {
        return error.SwapchainInvalid;
    }
}
