const windows = @import("std").os.windows;

pub usingnamespace windows.kernel32;
pub usingnamespace windows.user32;

pub const FARPROC = windows.FARPROC;
pub const HINSTANCE = windows.HINSTANCE;
pub const HMODULE = windows.HMODULE;
pub const HANDLE = windows.HANDLE;
pub const BOOL = windows.BOOL;
pub const UINT = windows.UINT;
pub const DWORD = windows.DWORD;
pub const LPCSTR = windows.LPCSTR;
pub const LPCWSTR = windows.LPCWSTR;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const INFINITE = windows.INFINITE;
pub const TRUE = windows.TRUE;
pub const FALSE = windows.FALSE;
pub const WAIT_OBJECT_0 = windows.WAIT_OBJECT_0;
pub const WAIT_TIMEOUT = windows.WAIT_TIMEOUT;
pub const WAIT_ABANDONED = windows.WAIT_ABANDONED;
pub const WAIT_FAILED = windows.WAIT_FAILED;
pub const PAGE_READWRITE = windows.PAGE_READWRITE;
pub const FILE_MAP_ALL_ACCESS = 983071;

pub extern "kernel32" fn LoadLibraryA(
    lpLibFileName: LPCSTR,
) ?HMODULE;

pub extern "kernel32" fn CreateFileMappingW(
    hFile: HANDLE,
    lpFileMappingAttributes: ?*SECURITY_ATTRIBUTES,
    flProtect: DWORD,
    dwMaximumSizeHigh: DWORD,
    dwMaximumSizeLow: DWORD,
    lpName: ?LPCWSTR,
) callconv(windows.WINAPI) ?HANDLE;

pub extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: HANDLE,
    dwDesiredAccess: DWORD,
    dwFileOffsetHigh: DWORD,
    dwFileOffsetLow: DWORD,
    dwNumberOfBytesToMap: usize,
) callconv(windows.WINAPI) ?*anyopaque;

pub extern "kernel32" fn UnmapViewOfFile(
    lpBaseAddress: *anyopaque,
) callconv(windows.WINAPI) BOOL;

pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*SECURITY_ATTRIBUTES,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?LPCWSTR,
) callconv(windows.WINAPI) ?HANDLE;

pub extern "kernel32" fn ResetEvent(
    hEvent: windows.HANDLE,
) callconv(windows.WINAPI) BOOL;

pub extern "kernel32" fn SetEvent(
    hEvent: windows.HANDLE,
) callconv(windows.WINAPI) BOOL;

pub extern "kernel32" fn CreateMutexW(
    lpMutexAttributes: ?*SECURITY_ATTRIBUTES,
    bInitialOwner: BOOL,
    lpName: ?LPCWSTR,
) callconv(windows.WINAPI) HANDLE;

pub extern "kernel32" fn ReleaseMutex(
    hMutex: HANDLE,
) callconv(windows.WINAPI) BOOL;

pub extern "user32" fn GetDpiForSystem() UINT;
