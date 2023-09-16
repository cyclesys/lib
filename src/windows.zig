const windows = @import("std").os.windows;

pub usingnamespace windows.kernel32;
pub usingnamespace windows.user32;

pub const HANDLE = windows.HANDLE;
pub const BOOL = windows.BOOL;
pub const UINT = windows.UINT;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const INFINITE = windows.INFINITE;
pub const WAIT_OBJECT_0 = windows.WAIT_OBJECT_0;
pub const WAIT_TIMEOUT = windows.WAIT_TIMEOUT;
pub const WAIT_ABANDONED = windows.WAIT_ABANDONED;
pub const WAIT_FAILED = windows.WAIT_FAILED;
pub const PAGE_READWRITE = windows.PAGE_READWRITE;
pub const FILE_MAP_ALL_ACCESS = 983071;

pub extern "kernel32" fn CreateFileMappingW(
    hFile: windows.HANDLE,
    lpFileMappingAttributes: ?*windows.SECURITY_ATTRIBUTES,
    flProtect: windows.DWORD,
    dwMaximumSizeHigh: windows.DWORD,
    dwMaximumSizeLow: windows.DWORD,
    lpName: ?windows.LPCWSTR,
) callconv(windows.WINAPI) ?windows.HANDLE;

pub extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: windows.HANDLE,
    dwDesiredAccess: windows.DWORD,
    dwFileOffsetHigh: windows.DWORD,
    dwFileOffsetLow: windows.DWORD,
    dwNumberOfBytesToMap: usize,
) callconv(windows.WINAPI) ?*anyopaque;

pub extern "kernel32" fn UnmapViewOfFile(
    lpBaseAddress: *anyopaque,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES,
    bManualReset: windows.BOOL,
    bInitialState: windows.BOOL,
    lpName: ?windows.LPCWSTR,
) callconv(windows.WINAPI) ?windows.HANDLE;

pub extern "kernel32" fn ResetEvent(
    hEvent: windows.HANDLE,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "kernel32" fn SetEvent(
    hEvent: windows.HANDLE,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "user32" fn GetDpiForSystem() UINT;
