// SPDX-License-Identifier: GPL-3.0-only
// 100% Pure Zig Windows GUI Installer & Uninstaller for EU5 RPC (v4.0.0).
// - Extracts embedded native eu5-rpc.exe, icons, LICENSE, and README.md to %LOCALAPPDATA%\EU5-RPC
// - Cleans up legacy Ruby files (lib/, bin/) and Eu5RpcRuby uninstall entry on upgrade (preserving config.toml)
// - Creates Desktop ("EU5 RPC.lnk") and Start Menu shortcuts using Win32 COM IShellLinkW
// - Registers Windows Add/Remove Programs uninstall support (--uninstall, --silent).
const std = @import("std");

const PAYLOAD_EXE = @embedFile("payload_exe");
const PAYLOAD_ICO = @embedFile("icon_ico");
const PAYLOAD_PNG = @embedFile("icon_png");
const PAYLOAD_LICENSE = @embedFile("license_txt");
const PAYLOAD_README = @embedFile("readme_md");

const HANDLE = ?*anyopaque;
const HKEY = ?*anyopaque;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);

const CSIDL_LOCAL_APPDATA: i32 = 0x001C;
const CSIDL_DESKTOPDIRECTORY: i32 = 0x0010;
const CSIDL_PROGRAMS: i32 = 0x0002;

const GENERIC_WRITE: u32 = 0x40000000;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

const KEY_WRITE: u32 = 0x20006;
const REG_SZ: u32 = 1;
const REG_DWORD: u32 = 4;
const ERROR_SUCCESS: i32 = 0;

const MB_OK: u32 = 0x00000000;
const MB_OKCANCEL: u32 = 0x00000001;
const MB_YESNO: u32 = 0x00000004;
const MB_ICONERROR: u32 = 0x00000010;
const MB_ICONQUESTION: u32 = 0x00000020;
const MB_ICONINFORMATION: u32 = 0x00000040;
const IDOK: i32 = 1;
const IDYES: i32 = 6;

const COINIT_APARTMENTTHREADED: u32 = 0x2;
const CLSCTX_INPROC_SERVER: u32 = 0x1;

const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

const CLSID_ShellLink = GUID{
    .data1 = 0x00021401,
    .data2 = 0x0000,
    .data3 = 0x0000,
    .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};
const IID_IShellLinkW = GUID{
    .data1 = 0x000214F9,
    .data2 = 0x0000,
    .data3 = 0x0000,
    .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};
const IID_IPersistFile = GUID{
    .data1 = 0x0000010B,
    .data2 = 0x0000,
    .data3 = 0x0000,
    .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

const FILETIME = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,
};

const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn RemoveDirectoryW(lpPathName: [*:0]const u16) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: *u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) i32;
extern "kernel32" fn SetFileAttributesW(lpFileName: [*:0]const u16, dwFileAttributes: u32) callconv(.winapi) i32;
extern "kernel32" fn CopyFileW(lpExistingFileName: [*:0]const u16, lpNewFileName: [*:0]const u16, bFailIfExists: i32) callconv(.winapi) i32;
extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) i32;
extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.winapi) i32;

extern "user32" fn MessageBoxW(hWnd: ?*anyopaque, lpText: [*:0]const u16, lpCaption: [*:0]const u16, uType: u32) callconv(.winapi) i32;

extern "shell32" fn SHGetFolderPathW(hwnd: ?*anyopaque, csidl: i32, hToken: HANDLE, dwFlags: u32, pszPath: [*]u16) callconv(.winapi) i32;

extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: u32,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) i32;

extern "advapi32" fn RegCreateKeyExW(
    hKey: HKEY,
    lpSubKey: [*:0]const u16,
    Reserved: u32,
    lpClass: ?[*:0]const u16,
    dwOptions: u32,
    samDesired: u32,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *HKEY,
    lpdwDisposition: ?*u32,
) callconv(.winapi) i32;
extern "advapi32" fn RegSetValueExW(
    hKey: HKEY,
    lpValueName: [*:0]const u16,
    Reserved: u32,
    dwType: u32,
    lpData: [*]const u8,
    cbData: u32,
) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteTreeW(hKey: HKEY, lpSubKey: ?[*:0]const u16) callconv(.winapi) i32;

const APP_DISPLAY_NAME = std.unicode.utf8ToUtf16LeStringLiteral("EU5 RPC (Europa Universalis V)");
const APP_VERSION = std.unicode.utf8ToUtf16LeStringLiteral("4.0.0");
const APP_PUBLISHER = std.unicode.utf8ToUtf16LeStringLiteral("Buntato");
const UNINSTALL_REG_KEY = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Eu5RpcZig");
const LEGACY_UNINSTALL_REG_KEY = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Eu5RpcRuby");

fn utf16Len(ptr: [*:0]const u16) usize {
    var i: usize = 0;
    while (ptr[i] != 0) : (i += 1) {}
    return i;
}

fn concatW(out: []u16, parts: []const []const u16) [:0]u16 {
    var pos: usize = 0;
    for (parts) |p| {
        for (p) |ch| {
            if (pos + 1 >= out.len) break;
            out[pos] = ch;
            pos += 1;
        }
    }
    out[pos] = 0;
    return out[0..pos :0];
}

fn writeFileW(path: [*:0]const u16, data: []const u8) bool {
    const h = CreateFileW(path, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(h);

    var off: usize = 0;
    while (off < data.len) {
        const chunk: u32 = @intCast(@min(data.len - off, 1024 * 1024));
        var written: u32 = 0;
        if (WriteFile(h, data.ptr + off, chunk, &written, null) == 0 or written != chunk) {
            return false;
        }
        off += written;
    }
    return true;
}

fn getSpecialFolder(csidl: i32, out: []u16) ?[]const u16 {
    if (out.len < 260) return null;
    @memset(out, 0);
    if (SHGetFolderPathW(null, csidl, null, 0, out.ptr) != 0) return null;
    const len = utf16Len(@ptrCast(out.ptr));
    if (len == 0) return null;
    return out[0..len];
}

fn getInstallDir(out: []u16) [:0]u16 {
    var local_app: [300]u16 = undefined;
    if (getSpecialFolder(CSIDL_LOCAL_APPDATA, &local_app)) |dir| {
        return concatW(out, &.{ dir, std.unicode.utf8ToUtf16LeStringLiteral("\\EU5-RPC") });
    }
    return concatW(out, &.{std.unicode.utf8ToUtf16LeStringLiteral("C:\\EU5-RPC")});
}

fn vtableCall(obj: *anyopaque, comptime idx: usize, comptime FnType: type) FnType {
    const vt: [*]const usize = @as(*const [*]const usize, @ptrCast(@alignCast(obj))).*;
    return @ptrFromInt(vt[idx]);
}

const QueryInterfaceFn = *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) i32;
const ReleaseFn = *const fn (*anyopaque) callconv(.winapi) u32;
const SetStrFn = *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) i32;
const SetIconFn = *const fn (*anyopaque, [*:0]const u16, i32) callconv(.winapi) i32;
const SaveFn = *const fn (*anyopaque, [*:0]const u16, i32) callconv(.winapi) i32;

fn createShortcut(
    lnk_path: [*:0]const u16,
    target_exe: [*:0]const u16,
    work_dir: [*:0]const u16,
    icon_path: [*:0]const u16,
    description: [*:0]const u16,
) bool {
    var psl_opt: ?*anyopaque = null;
    if (CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &psl_opt) < 0) return false;
    const psl = psl_opt orelse return false;
    defer _ = vtableCall(psl, 2, ReleaseFn)(psl);

    _ = vtableCall(psl, 20, SetStrFn)(psl, target_exe);
    _ = vtableCall(psl, 9, SetStrFn)(psl, work_dir);
    _ = vtableCall(psl, 7, SetStrFn)(psl, description);
    _ = vtableCall(psl, 17, SetIconFn)(psl, icon_path, 0);

    var ppf_opt: ?*anyopaque = null;
    if (vtableCall(psl, 0, QueryInterfaceFn)(psl, &IID_IPersistFile, &ppf_opt) < 0) return false;
    const ppf = ppf_opt orelse return false;
    defer _ = vtableCall(ppf, 2, ReleaseFn)(ppf);

    return vtableCall(ppf, 6, SaveFn)(ppf, lnk_path, 1) >= 0;
}

fn regSetStr(hkey: HKEY, name: [*:0]const u16, val: [*:0]const u16) void {
    const bytes = (utf16Len(val) + 1) * 2;
    _ = RegSetValueExW(hkey, name, 0, REG_SZ, @ptrCast(val), @intCast(bytes));
}

fn registerUninstall(install_dir: [:0]const u16, setup_copy: [:0]const u16, icon_path: [:0]const u16) void {
    // Clean up legacy Ruby uninstall entry if upgrading from v0.3.x
    _ = RegDeleteTreeW(HKEY_CURRENT_USER, LEGACY_UNINSTALL_REG_KEY);

    var hkey: HKEY = null;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, UNINSTALL_REG_KEY, 0, null, 0, KEY_WRITE, null, &hkey, null) != ERROR_SUCCESS) {
        return;
    }
    defer _ = RegCloseKey(hkey);

    var cmd_buf: [600]u16 = undefined;
    const cmd = concatW(&cmd_buf, &.{
        std.unicode.utf8ToUtf16LeStringLiteral("\""),
        setup_copy,
        std.unicode.utf8ToUtf16LeStringLiteral("\" --uninstall"),
    });

    regSetStr(hkey, std.unicode.utf8ToUtf16LeStringLiteral("DisplayName"), APP_DISPLAY_NAME);
    regSetStr(hkey, std.unicode.utf8ToUtf16LeStringLiteral("DisplayVersion"), APP_VERSION);
    regSetStr(hkey, std.unicode.utf8ToUtf16LeStringLiteral("Publisher"), APP_PUBLISHER);
    regSetStr(hkey, std.unicode.utf8ToUtf16LeStringLiteral("InstallLocation"), install_dir.ptr);
    regSetStr(hkey, std.unicode.utf8ToUtf16LeStringLiteral("DisplayIcon"), icon_path.ptr);
    regSetStr(hkey, std.unicode.utf8ToUtf16LeStringLiteral("UninstallString"), cmd.ptr);

    const one: u32 = 1;
    _ = RegSetValueExW(hkey, std.unicode.utf8ToUtf16LeStringLiteral("NoModify"), 0, REG_DWORD, @ptrCast(&one), 4);
    _ = RegSetValueExW(hkey, std.unicode.utf8ToUtf16LeStringLiteral("NoRepair"), 0, REG_DWORD, @ptrCast(&one), 4);
}

fn removeDirRecursive(dir: []const u16) void {
    var pat_buf: [600]u16 = undefined;
    const pat = concatW(&pat_buf, &.{ dir, std.unicode.utf8ToUtf16LeStringLiteral("\\*") });

    var fd: WIN32_FIND_DATAW = undefined;
    const h = FindFirstFileW(pat.ptr, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        defer _ = FindClose(h);
        while (true) {
            const name_ptr: [*:0]const u16 = @ptrCast(&fd.cFileName);
            const name = fd.cFileName[0..utf16Len(name_ptr)];
            const is_dot = (name.len == 1 and name[0] == '.') or (name.len == 2 and name[0] == '.' and name[1] == '.');
            if (!is_dot) {
                var child_buf: [600]u16 = undefined;
                const child = concatW(&child_buf, &.{ dir, std.unicode.utf8ToUtf16LeStringLiteral("\\"), name });
                if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                    removeDirRecursive(child);
                } else {
                    _ = SetFileAttributesW(child.ptr, FILE_ATTRIBUTE_NORMAL);
                    _ = DeleteFileW(child.ptr);
                }
            }
            if (FindNextFileW(h, &fd) == 0) break;
        }
    }
    var dir_z: [600]u16 = undefined;
    const d = concatW(&dir_z, &.{dir});
    _ = RemoveDirectoryW(d.ptr);
}

fn doUninstall(silent: bool) void {
    var install_buf: [400]u16 = undefined;
    const install_dir = getInstallDir(&install_buf);

    if (!silent) {
        const res = MessageBoxW(
            null,
            std.unicode.utf8ToUtf16LeStringLiteral("Uninstall EU5 RPC and remove its Desktop and Start Menu shortcuts?"),
            APP_DISPLAY_NAME,
            MB_ICONQUESTION | MB_YESNO,
        );
        if (res != IDYES) return;
    }

    var desk_dir: [300]u16 = undefined;
    if (getSpecialFolder(CSIDL_DESKTOPDIRECTORY, &desk_dir)) |d| {
        var lnk: [400]u16 = undefined;
        const p = concatW(&lnk, &.{ d, std.unicode.utf8ToUtf16LeStringLiteral("\\EU5 RPC.lnk") });
        _ = DeleteFileW(p.ptr);
    }
    var prog_dir: [300]u16 = undefined;
    if (getSpecialFolder(CSIDL_PROGRAMS, &prog_dir)) |d| {
        var lnk: [400]u16 = undefined;
        const p = concatW(&lnk, &.{ d, std.unicode.utf8ToUtf16LeStringLiteral("\\EU5 RPC.lnk") });
        _ = DeleteFileW(p.ptr);
    }

    _ = RegDeleteTreeW(HKEY_CURRENT_USER, UNINSTALL_REG_KEY);
    _ = RegDeleteTreeW(HKEY_CURRENT_USER, LEGACY_UNINSTALL_REG_KEY);
    removeDirRecursive(install_dir);

    if (!silent) {
        _ = MessageBoxW(
            null,
            std.unicode.utf8ToUtf16LeStringLiteral("EU5 RPC has been uninstalled."),
            APP_DISPLAY_NAME,
            MB_ICONINFORMATION | MB_OK,
        );
    }
}

fn doInstall(silent: bool) void {
    @setEvalBranchQuota(10000);
    var install_buf: [400]u16 = undefined;
    const install_dir = getInstallDir(&install_buf);

    if (!silent) {
        var prompt_buf: [1024]u16 = undefined;
        const prompt = concatW(&prompt_buf, &.{
            std.unicode.utf8ToUtf16LeStringLiteral("Install EU5 RPC (Europa Universalis V Discord Rich Presence) v4.0.0?\n\nInstall folder:\n"),
            install_dir,
            std.unicode.utf8ToUtf16LeStringLiteral("\n\nThis will also create an \"EU5 RPC\" shortcut on your Desktop to launch Europa Universalis V with Discord Rich Presence."),
        });
        if (MessageBoxW(null, prompt.ptr, APP_DISPLAY_NAME, MB_ICONINFORMATION | MB_OKCANCEL) != IDOK) {
            return;
        }
    }

    _ = CreateDirectoryW(install_dir.ptr, null);

    // Clean up legacy Ruby installation folders on upgrade (preserving config.toml and logs/)
    var old_lib_buf: [512]u16 = undefined;
    var old_bin_buf: [512]u16 = undefined;
    const old_lib = concatW(&old_lib_buf, &.{ install_dir, std.unicode.utf8ToUtf16LeStringLiteral("\\lib") });
    const old_bin = concatW(&old_bin_buf, &.{ install_dir, std.unicode.utf8ToUtf16LeStringLiteral("\\bin") });
    removeDirRecursive(old_lib);
    removeDirRecursive(old_bin);

    var assets_buf: [512]u16 = undefined;
    const assets_dir = concatW(&assets_buf, &.{ install_dir, std.unicode.utf8ToUtf16LeStringLiteral("\\assets") });
    _ = CreateDirectoryW(assets_dir.ptr, null);

    var exe_buf: [512]u16 = undefined;
    var ico_buf: [512]u16 = undefined;
    var png_buf: [512]u16 = undefined;
    var lic_buf: [512]u16 = undefined;
    var rdm_buf: [512]u16 = undefined;
    var setup_copy_buf: [512]u16 = undefined;

    const exe_path = concatW(&exe_buf, &.{ install_dir, std.unicode.utf8ToUtf16LeStringLiteral("\\eu5-rpc.exe") });
    const ico_path = concatW(&ico_buf, &.{ install_dir, std.unicode.utf8ToUtf16LeStringLiteral("\\assets\\icon.ico") });
    const png_path = concatW(&png_buf, &.{ install_dir, std.unicode.utf8ToUtf16LeStringLiteral("\\assets\\icon.png") });
    const lic_path = concatW(&lic_buf, &.{ install_dir, std.unicode.utf8ToUtf16LeStringLiteral("\\LICENSE") });
    const rdm_path = concatW(&rdm_buf, &.{ install_dir, std.unicode.utf8ToUtf16LeStringLiteral("\\README.md") });
    const setup_copy = concatW(&setup_copy_buf, &.{ install_dir, std.unicode.utf8ToUtf16LeStringLiteral("\\EU5-RPC-Setup.exe") });

    const ok = writeFileW(exe_path.ptr, PAYLOAD_EXE) and
        writeFileW(ico_path.ptr, PAYLOAD_ICO) and
        writeFileW(png_path.ptr, PAYLOAD_PNG) and
        writeFileW(lic_path.ptr, PAYLOAD_LICENSE) and
        writeFileW(rdm_path.ptr, PAYLOAD_README);

    if (!ok) {
        if (!silent) {
            _ = MessageBoxW(
                null,
                std.unicode.utf8ToUtf16LeStringLiteral("Installation failed while writing application files."),
                APP_DISPLAY_NAME,
                MB_ICONERROR | MB_OK,
            );
        }
        return;
    }

    var self_path: [400]u16 = std.mem.zeroes([400]u16);
    if (GetModuleFileNameW(null, &self_path, 399) > 0) {
        _ = CopyFileW(@ptrCast(&self_path), setup_copy.ptr, 0);
    }

    _ = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    const desc = std.unicode.utf8ToUtf16LeStringLiteral("Launch Europa Universalis V with Discord Rich Presence");
    var desk_dir: [300]u16 = undefined;
    if (getSpecialFolder(CSIDL_DESKTOPDIRECTORY, &desk_dir)) |d| {
        var lnk: [400]u16 = undefined;
        const p = concatW(&lnk, &.{ d, std.unicode.utf8ToUtf16LeStringLiteral("\\EU5 RPC.lnk") });
        _ = createShortcut(p.ptr, exe_path.ptr, install_dir.ptr, ico_path.ptr, desc);
    }
    var prog_dir: [300]u16 = undefined;
    if (getSpecialFolder(CSIDL_PROGRAMS, &prog_dir)) |d| {
        var lnk: [400]u16 = undefined;
        const p = concatW(&lnk, &.{ d, std.unicode.utf8ToUtf16LeStringLiteral("\\EU5 RPC.lnk") });
        _ = createShortcut(p.ptr, exe_path.ptr, install_dir.ptr, ico_path.ptr, desc);
    }
    CoUninitialize();

    registerUninstall(install_dir, setup_copy, ico_path);

    if (!silent) {
        _ = MessageBoxW(
            null,
            std.unicode.utf8ToUtf16LeStringLiteral("Installation complete!\n\nDouble-click \"EU5 RPC\" on your Desktop to launch Europa Universalis V with Discord Rich Presence."),
            APP_DISPLAY_NAME,
            MB_ICONINFORMATION | MB_OK,
        );
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var silent = false;
    var uninstall = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--silent")) silent = true;
        if (std.mem.eql(u8, arg, "--uninstall")) uninstall = true;
    }

    if (uninstall) {
        doUninstall(silent);
    } else {
        doInstall(silent);
    }
}
