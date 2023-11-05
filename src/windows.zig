const win = @import("std").os.windows;

pub usingnamespace win.kernel32;

pub const FARPROC = win.FARPROC;
pub const HINSTANCE = win.HINSTANCE;
pub const HMODULE = win.HMODULE;
pub const HANDLE = win.HANDLE;
pub const BOOL = win.BOOL;
pub const UINT = win.UINT;
pub const DWORD = win.DWORD;
pub const LPCSTR = win.LPCSTR;
pub const LPCWSTR = win.LPCWSTR;
pub const SECURITY_ATTRIBUTES = win.SECURITY_ATTRIBUTES;
pub const INVALID_HANDLE_VALUE = win.INVALID_HANDLE_VALUE;
pub const INFINITE = win.INFINITE;
pub const TRUE = win.TRUE;
pub const FALSE = win.FALSE;
pub const WAIT_OBJECT_0 = win.WAIT_OBJECT_0;
pub const WAIT_TIMEOUT = win.WAIT_TIMEOUT;
pub const WAIT_ABANDONED = win.WAIT_ABANDONED;
pub const WAIT_FAILED = win.WAIT_FAILED;
pub const PAGE_READWRITE = win.PAGE_READWRITE;
pub const FILE_MAP_ALL_ACCESS = 983071;

pub extern "kernel32" fn LoadLibraryA(lpLibFileName: win.LPCSTR) ?win.HMODULE;

pub extern "kernel32" fn CreateFileMappingW(
    hFile: win.HANDLE,
    lpFileMappingAttributes: ?*win.SECURITY_ATTRIBUTES,
    flProtect: win.DWORD,
    dwMaximumSizeHigh: win.DWORD,
    dwMaximumSizeLow: win.DWORD,
    lpName: ?win.LPCWSTR,
) callconv(win.WINAPI) ?win.HANDLE;

pub extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: win.HANDLE,
    dwDesiredAccess: win.DWORD,
    dwFileOffsetHigh: win.DWORD,
    dwFileOffsetLow: win.DWORD,
    dwNumberOfBytesToMap: usize,
) callconv(win.WINAPI) ?*anyopaque;

pub extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: *anyopaque) callconv(win.WINAPI) win.BOOL;

pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*win.SECURITY_ATTRIBUTES,
    bManualReset: win.BOOL,
    bInitialState: win.BOOL,
    lpName: ?win.LPCWSTR,
) callconv(win.WINAPI) ?win.HANDLE;

pub extern "kernel32" fn ResetEvent(hEvent: win.HANDLE) callconv(win.WINAPI) win.BOOL;

pub extern "kernel32" fn SetEvent(hEvent: win.HANDLE) callconv(win.WINAPI) win.BOOL;

pub extern "kernel32" fn CreateMutexW(
    lpMutexAttributes: ?*win.SECURITY_ATTRIBUTES,
    bInitialOwner: win.BOOL,
    lpName: ?win.LPCWSTR,
) callconv(win.WINAPI) win.HANDLE;

pub extern "kernel32" fn ReleaseMutex(hMutex: win.HANDLE) callconv(win.WINAPI) win.BOOL;

pub extern "user32" fn GetDpiForSystem() win.UINT;
