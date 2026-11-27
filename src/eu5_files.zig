// SPDX-License-Identifier: GPL-3.0-only
// Cross-platform, user-, distro-, desktop-, Proton-, and Windows-Unicode-agnostic
// filesystem, Steam library, Proton/Wine prefix, and launcher utilities for EU5 RPC.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");

const FILE = anyopaque;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *FILE) c_long;
extern "c" fn fclose(stream: *FILE) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;

const win = if (builtin.os.tag == .windows) struct {
    const HKEY = ?*anyopaque;
    const HANDLE = ?*anyopaque;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
    const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);
    const KEY_READ: u32 = 0x20019;
    const ERROR_SUCCESS: i32 = 0;
    const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    const CSIDL_PERSONAL: i32 = 0x0005;
    const GetFileExInfoStandard: u32 = 0;
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const FILE_SHARE_READ: u32 = 0x00000001;
    const FILE_SHARE_WRITE: u32 = 0x00000002;
    const FILE_SHARE_DELETE: u32 = 0x00000004;
    const OPEN_EXISTING: u32 = 3;
    const CREATE_ALWAYS: u32 = 2;
    const FILE_BEGIN: u32 = 0;
    const INFINITE: u32 = 0xFFFFFFFF;

    const FILETIME = extern struct {
        dwLowDateTime: u32,
        dwHighDateTime: u32,
    };

    const WIN32_FILE_ATTRIBUTE_DATA = extern struct {
        dwFileAttributes: u32,
        ftCreationTime: FILETIME,
        ftLastAccessTime: FILETIME,
        ftLastWriteTime: FILETIME,
        nFileSizeHigh: u32,
        nFileSizeLow: u32,
    };

    const STARTUPINFOW = extern struct {
        cb: u32,
        lpReserved: ?[*:0]u16,
        lpDesktop: ?[*:0]u16,
        lpTitle: ?[*:0]u16,
        dwX: u32,
        dwY: u32,
        dwXSize: u32,
        dwYSize: u32,
        dwXCountChars: u32,
        dwYCountChars: u32,
        dwFillAttribute: u32,
        dwFlags: u32,
        wShowWindow: u16,
        cbReserved2: u16,
        lpReserved2: ?*u8,
        hStdInput: HANDLE,
        hStdOutput: HANDLE,
        hStdError: HANDLE,
    };

    const PROCESS_INFORMATION = extern struct {
        hProcess: HANDLE,
        hThread: HANDLE,
        dwProcessId: u32,
        dwThreadId: u32,
    };

    extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GetFileAttributesExW(
        lpFileName: [*:0]const u16,
        fInfoLevelId: u32,
        lpFileInformation: *WIN32_FILE_ATTRIBUTE_DATA,
    ) callconv(.winapi) i32;
    extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: HANDLE,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: u32,
        lpNumberOfBytesRead: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn SetFilePointerEx(
        hFile: HANDLE,
        liDistanceToMove: i64,
        lpNewFilePointer: ?*i64,
        dwMoveMethod: u32,
    ) callconv(.winapi) i32;
    extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) i32;
    extern "kernel32" fn GetEnvironmentVariableW(
        lpName: [*:0]const u16,
        lpBuffer: [*]u16,
        nSize: u32,
    ) callconv(.winapi) u32;
    extern "kernel32" fn ExpandEnvironmentStringsW(
        lpSrc: [*:0]const u16,
        lpDst: [*]u16,
        nSize: u32,
    ) callconv(.winapi) u32;
    extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;
    extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?[*:0]const u16,
        lpCommandLine: ?[*:0]u16,
        lpProcessAttributes: ?*anyopaque,
        lpThreadAttributes: ?*anyopaque,
        bInheritHandles: i32,
        dwCreationFlags: u32,
        lpEnvironment: ?*anyopaque,
        lpCurrentDirectory: ?[*:0]const u16,
        lpStartupInfo: *STARTUPINFOW,
        lpProcessInformation: *PROCESS_INFORMATION,
    ) callconv(.winapi) i32;
    extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
    extern "advapi32" fn RegOpenKeyExW(
        hKey: HKEY,
        lpSubKey: [*:0]const u16,
        ulOptions: u32,
        samDesired: u32,
        phkResult: *HKEY,
    ) callconv(.winapi) i32;
    extern "advapi32" fn RegQueryValueExW(
        hKey: HKEY,
        lpValueName: [*:0]const u16,
        lpReserved: ?*u32,
        lpType: ?*u32,
        lpData: ?[*]u8,
        lpcbData: ?*u32,
    ) callconv(.winapi) i32;
    extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;
    extern "shell32" fn SHGetFolderPathW(
        hwnd: ?*anyopaque,
        csidl: i32,
        hToken: HANDLE,
        dwFlags: u32,
        pszPath: [*]u16,
    ) callconv(.winapi) i32;
} else struct {};

const posix = if (builtin.os.tag != .windows) struct {
    const DIR = anyopaque;
    const F_OK: c_int = 0;
    extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
    extern "c" fn closedir(dirp: *DIR) c_int;
    extern "c" fn mkdir(pathname: [*:0]const u8, mode: u32) c_int;
    extern "c" fn fork() c_int;
    extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn _exit(status: c_int) noreturn;
} else struct {};

const bufPrintZ = root.bufPrintZ;

pub fn utf8ToUtf16Z(src: []const u8, out: []u16) ?[:0]u16 {
    if (out.len == 0) return null;
    const n = std.unicode.utf8ToUtf16Le(out[0 .. out.len - 1], src) catch return null;
    out[n] = 0;
    return out[0..n :0];
}

pub fn utf16ToUtf8(src: []const u16, out: []u8) ?[]const u8 {
    const n = std.unicode.utf16LeToUtf8(out, src) catch return null;
    return out[0..n];
}

pub fn utf16Len(ptr: [*:0]const u16) usize {
    var i: usize = 0;
    while (ptr[i] != 0) : (i += 1) {}
    return i;
}

/// Reads an environment variable as UTF-8 (Win32 `GetEnvironmentVariableW` on Windows, `getenv` on POSIX).
pub fn getEnvUtf8(name: [:0]const u8, out_buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        var name_w: [128]u16 = undefined;
        const nw = utf8ToUtf16Z(name, &name_w) orelse return null;
        var val_w: [1024]u16 = undefined;
        const n = win.GetEnvironmentVariableW(nw.ptr, &val_w, val_w.len);
        if (n == 0 or n >= val_w.len) return null;
        return utf16ToUtf8(val_w[0..n], out_buf);
    } else {
        const p = getenv(name.ptr) orelse return null;
        const s = std.mem.span(p);
        if (s.len == 0 or s.len > out_buf.len) return null;
        @memcpy(out_buf[0..s.len], s);
        return out_buf[0..s.len];
    }
}

pub fn getModuleDirUtf8(out_buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var wbuf: [1024]u16 = undefined;
    const n = win.GetModuleFileNameW(null, &wbuf, wbuf.len - 1);
    if (n == 0 or n >= wbuf.len) return null;
    var u8buf: [1024]u8 = undefined;
    const full = utf16ToUtf8(wbuf[0..n], &u8buf) orelse return null;
    const sep = std.mem.lastIndexOfAny(u8, full, "\\/") orelse return null;
    if (sep == 0 or sep > out_buf.len) return null;
    @memcpy(out_buf[0..sep], full[0..sep]);
    return out_buf[0..sep];
}

pub fn ensureDirRecursive(path: []const u8) void {
    if (path.len == 0) return;
    if (builtin.os.tag == .windows) {
        var wbuf: [1024]u16 = undefined;
        const w = utf8ToUtf16Z(path, &wbuf) orelse return;
        for (w) |*ch| {
            if (ch.* == '/') ch.* = '\\';
        }
        const start: usize = if (w.len >= 3 and w[1] == ':') 3 else 1;
        var i: usize = start;
        while (i < w.len) : (i += 1) {
            if (w[i] == '\\') {
                w[i] = 0;
                _ = win.CreateDirectoryW(@ptrCast(w.ptr), null);
                w[i] = '\\';
            }
        }
        _ = win.CreateDirectoryW(w.ptr, null);
    } else {
        var buf: [1024]u8 = undefined;
        if (path.len >= buf.len) return;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;

        var i: usize = 1;
        while (i < path.len) : (i += 1) {
            if (buf[i] == '/') {
                buf[i] = 0;
                _ = posix.mkdir(@ptrCast(&buf), 0o755);
                buf[i] = '/';
            }
        }
        _ = posix.mkdir(@ptrCast(&buf), 0o755);
    }
}

pub fn fileExists(path_z: [*:0]const u8) bool {
    const path = std.mem.span(path_z);
    if (builtin.os.tag == .windows) {
        var wbuf: [1024]u16 = undefined;
        const w = utf8ToUtf16Z(path, &wbuf) orelse return false;
        const attr = win.GetFileAttributesW(w.ptr);
        return attr != win.INVALID_FILE_ATTRIBUTES and (attr & win.FILE_ATTRIBUTE_DIRECTORY) == 0;
    } else {
        if (posix.access(path_z, posix.F_OK) != 0) return false;
        return !dirExists(path_z);
    }
}

pub fn dirExists(path_z: [*:0]const u8) bool {
    const path = std.mem.span(path_z);
    if (builtin.os.tag == .windows) {
        var wbuf: [1024]u16 = undefined;
        const w = utf8ToUtf16Z(path, &wbuf) orelse return false;
        const attr = win.GetFileAttributesW(w.ptr);
        return attr != win.INVALID_FILE_ATTRIBUTES and (attr & win.FILE_ATTRIBUTE_DIRECTORY) != 0;
    } else {
        const d = posix.opendir(path_z) orelse return false;
        _ = posix.closedir(d);
        return true;
    }
}

pub fn fileMtime(path_z: [*:0]const u8) ?i64 {
    const path = std.mem.span(path_z);
    if (builtin.os.tag == .windows) {
        var wbuf: [1024]u16 = undefined;
        const w = utf8ToUtf16Z(path, &wbuf) orelse return null;
        var info: win.WIN32_FILE_ATTRIBUTE_DATA = undefined;
        if (win.GetFileAttributesExW(w.ptr, win.GetFileExInfoStandard, &info) == 0) return null;
        if ((info.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY) != 0) return null;
        const ticks: u64 = (@as(u64, info.ftLastWriteTime.dwHighDateTime) << 32) | info.ftLastWriteTime.dwLowDateTime;
        const unix_secs: i64 = @as(i64, @intCast(ticks / 10_000_000)) - 11_644_473_600;
        return unix_secs;
    } else if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
        const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, path_z, 0, .{ .MTIME = true }, &stx);
        if (std.os.linux.errno(rc) == .SUCCESS and stx.mask.MTIME) {
            return stx.mtime.sec;
        }
        return null;
    } else {
        return if (fileExists(path_z)) 1 else null;
    }
}

pub fn fileSize(path_z: [*:0]const u8) ?u64 {
    const path = std.mem.span(path_z);
    if (builtin.os.tag == .windows) {
        var wbuf: [1024]u16 = undefined;
        const w = utf8ToUtf16Z(path, &wbuf) orelse return null;
        var info: win.WIN32_FILE_ATTRIBUTE_DATA = undefined;
        if (win.GetFileAttributesExW(w.ptr, win.GetFileExInfoStandard, &info) == 0) return null;
        if ((info.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY) != 0) return null;
        return (@as(u64, info.nFileSizeHigh) << 32) | info.nFileSizeLow;
    } else if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
        const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, path_z, 0, .{ .SIZE = true }, &stx);
        if (std.os.linux.errno(rc) == .SUCCESS and stx.mask.SIZE) {
            return stx.size;
        }
        return null;
    } else {
        const fp = fopen(path_z, "rb") orelse return null;
        defer _ = fclose(fp);
        _ = fseek(fp, 0, SEEK_END);
        const sz = ftell(fp);
        return if (sz >= 0) @intCast(sz) else null;
    }
}

/// Reads bytes from `path` starting at `offset` into `out_buf` with full shared-read/write access on Windows
/// so actively-written EU5 logs and saves never cause sharing violations.
pub fn readFileRange(path_z: [*:0]const u8, offset: u64, out_buf: []u8) ?usize {
    if (out_buf.len == 0) return 0;
    const path = std.mem.span(path_z);
    if (builtin.os.tag == .windows) {
        var wbuf: [1024]u16 = undefined;
        const w = utf8ToUtf16Z(path, &wbuf) orelse return null;
        const h = win.CreateFileW(
            w.ptr,
            win.GENERIC_READ,
            win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
            null,
            win.OPEN_EXISTING,
            win.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (h == win.INVALID_HANDLE_VALUE) return null;
        defer _ = win.CloseHandle(h);

        if (offset > 0) {
            if (win.SetFilePointerEx(h, @intCast(offset), null, win.FILE_BEGIN) == 0) return null;
        }
        var total: usize = 0;
        while (total < out_buf.len) {
            const chunk: u32 = @intCast(@min(out_buf.len - total, 1024 * 1024));
            var got: u32 = 0;
            if (win.ReadFile(h, out_buf.ptr + total, chunk, &got, null) == 0) break;
            if (got == 0) break;
            total += got;
        }
        return total;
    } else {
        const fp = fopen(path_z, "rb") orelse return null;
        defer _ = fclose(fp);
        if (offset > 0) {
            if (fseek(fp, @intCast(offset), SEEK_SET) != 0) return null;
        }
        return fread(out_buf.ptr, 1, out_buf.len, fp);
    }
}

pub fn readFileAlloc(alloc: std.mem.Allocator, path_z: [*:0]const u8, max_bytes: usize) ?[]u8 {
    const sz_u64 = fileSize(path_z) orelse return null;
    if (sz_u64 == 0 or sz_u64 > max_bytes) return null;
    const sz: usize = @intCast(sz_u64);
    const buf = alloc.alloc(u8, sz) catch return null;
    const got = readFileRange(path_z, 0, buf) orelse {
        alloc.free(buf);
        return null;
    };
    if (got == sz) return buf;
    return alloc.realloc(buf, got) catch buf[0..got];
}

pub fn writeFileAll(path_z: [*:0]const u8, data: []const u8) bool {
    const path = std.mem.span(path_z);
    if (builtin.os.tag == .windows) {
        var wbuf: [1024]u16 = undefined;
        const w = utf8ToUtf16Z(path, &wbuf) orelse return false;
        const h = win.CreateFileW(
            w.ptr,
            win.GENERIC_WRITE,
            win.FILE_SHARE_READ,
            null,
            win.CREATE_ALWAYS,
            win.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (h == win.INVALID_HANDLE_VALUE) return false;
        defer _ = win.CloseHandle(h);
        var off: usize = 0;
        while (off < data.len) {
            const chunk: u32 = @intCast(@min(data.len - off, 1024 * 1024));
            var written: u32 = 0;
            if (win.WriteFile(h, data.ptr + off, chunk, &written, null) == 0 or written != chunk) return false;
            off += written;
        }
        return true;
    } else {
        const fp = fopen(path_z, "wb") orelse return false;
        defer _ = fclose(fp);
        if (data.len == 0) return true;
        return fwrite(data.ptr, 1, data.len, fp) == data.len;
    }
}

pub fn deleteFileUtf8(path_z: [*:0]const u8) void {
    const path = std.mem.span(path_z);
    if (builtin.os.tag == .windows) {
        var wbuf: [1024]u16 = undefined;
        const w = utf8ToUtf16Z(path, &wbuf) orelse return;
        _ = win.DeleteFileW(w.ptr);
    }
}

fn readWinRegString(root_key: if (builtin.os.tag == .windows) win.HKEY else void, subkey_u8: []const u8, value_u8: []const u8, out_buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var sk_w: [256]u16 = undefined;
    var val_w: [128]u16 = undefined;
    const sk = utf8ToUtf16Z(subkey_u8, &sk_w) orelse return null;
    const vn = utf8ToUtf16Z(value_u8, &val_w) orelse return null;

    var hkey: win.HKEY = null;
    if (win.RegOpenKeyExW(root_key, sk.ptr, 0, win.KEY_READ, &hkey) != win.ERROR_SUCCESS) return null;
    defer _ = win.RegCloseKey(hkey);

    var raw_w: [1024]u16 = std.mem.zeroes([1024]u16);
    var byte_len: u32 = @intCast((raw_w.len - 1) * 2);
    var reg_type: u32 = 0;
    if (win.RegQueryValueExW(hkey, vn.ptr, null, &reg_type, @ptrCast(&raw_w), &byte_len) != win.ERROR_SUCCESS or byte_len < 2) {
        return null;
    }

    var exp_w: [1024]u16 = std.mem.zeroes([1024]u16);
    const exp_n = win.ExpandEnvironmentStringsW(@ptrCast(&raw_w), &exp_w, exp_w.len);
    const src_slice = if (exp_n > 1 and exp_n <= exp_w.len)
        exp_w[0 .. exp_n - 1]
    else
        raw_w[0..utf16Len(@ptrCast(&raw_w))];

    const s = utf16ToUtf8(src_slice, out_buf) orelse return null;
    return if (s.len > 0) s else null;
}

fn normalizeWinPathInPlace(buf: []u8, len: usize) []const u8 {
    for (buf[0..len]) |*ch| {
        if (ch.* == '/') ch.* = '\\';
    }
    var trimmed_len = len;
    while (trimmed_len > 3 and buf[trimmed_len - 1] == '\\') : (trimmed_len -= 1) {}
    return buf[0..trimmed_len];
}

pub fn findSteamRoot(buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const reg_queries = [_]struct { root_key: win.HKEY, subkey: []const u8, val: []const u8 }{
            .{ .root_key = win.HKEY_CURRENT_USER, .subkey = "Software\\Valve\\Steam", .val = "SteamPath" },
            .{ .root_key = win.HKEY_LOCAL_MACHINE, .subkey = "SOFTWARE\\WOW6432Node\\Valve\\Steam", .val = "InstallPath" },
            .{ .root_key = win.HKEY_LOCAL_MACHINE, .subkey = "SOFTWARE\\Valve\\Steam", .val = "InstallPath" },
        };
        for (reg_queries) |q| {
            var tmp: [512]u8 = undefined;
            if (readWinRegString(q.root_key, q.subkey, q.val, &tmp)) |s| {
                const norm = normalizeWinPathInPlace(&tmp, s.len);
                if (bufPrintZ(buf, "{s}", .{norm})) |p| {
                    if (dirExists(p.ptr)) return p;
                } else |_| {}
            }
        }
        const fallbacks = [_][:0]const u8{
            "C:\\Program Files (x86)\\Steam",
            "C:\\Program Files\\Steam",
        };
        for (fallbacks) |fb| {
            if (dirExists(fb.ptr)) {
                return bufPrintZ(buf, "{s}", .{fb}) catch null;
            }
        }
        return null;
    } else {
        var env_buf: [512]u8 = undefined;
        if (getEnvUtf8("STEAM_COMPAT_CLIENT_INSTALL_PATH", &env_buf)) |p| {
            const trimmed = std.mem.trimEnd(u8, p, "/");
            if (bufPrintZ(buf, "{s}", .{trimmed})) |cand| {
                if (dirExists(cand.ptr)) return cand;
            } else |_| {}
        }
        if (getEnvUtf8("XDG_DATA_HOME", &env_buf)) |xdg| {
            const trimmed = std.mem.trimEnd(u8, xdg, "/");
            if (bufPrintZ(buf, "{s}/Steam", .{trimmed})) |cand| {
                if (dirExists(cand.ptr)) return cand;
            } else |_| {}
        }
        var home_buf: [512]u8 = undefined;
        const home = getEnvUtf8("HOME", &home_buf) orelse return null;
        const rels = [_][]const u8{
            ".local/share/Steam",
            ".steam/steam",
            ".steam/root",
            ".steam/debian-installation",
            ".var/app/com.valvesoftware.Steam/.local/share/Steam",
            ".var/app/com.valvesoftware.Steam/.steam/steam",
            "snap/steam/common/.local/share/Steam",
            "snap/steam/common/.steam/steam",
        };
        for (rels) |rel| {
            const p = bufPrintZ(buf, "{s}/{s}", .{ home, rel }) catch continue;
            if (dirExists(p.ptr)) return p;
        }
        return null;
    }
}

pub fn findSteamClientLib(buf: []u8) ?[]const u8 {
    var root_buf: [512]u8 = undefined;
    if (builtin.os.tag == .windows) {
        const steam_root = findSteamRoot(&root_buf) orelse return null;
        const p = bufPrintZ(buf, "{s}\\steamclient64.dll", .{steam_root}) catch return null;
        return if (fileExists(p.ptr)) p else null;
    } else {
        var env_buf: [512]u8 = undefined;
        if (getEnvUtf8("STEAM_COMPAT_CLIENT_INSTALL_PATH", &env_buf)) |cp| {
            const trimmed = std.mem.trimEnd(u8, cp, "/");
            if (bufPrintZ(buf, "{s}/linux64/steamclient.so", .{trimmed})) |p| {
                if (fileExists(p.ptr)) return p;
            } else |_| {}
        }
        if (getEnvUtf8("XDG_DATA_HOME", &env_buf)) |xdg| {
            const trimmed = std.mem.trimEnd(u8, xdg, "/");
            if (bufPrintZ(buf, "{s}/Steam/linux64/steamclient.so", .{trimmed})) |p| {
                if (fileExists(p.ptr)) return p;
            } else |_| {}
        }
        var home_buf: [512]u8 = undefined;
        const home = getEnvUtf8("HOME", &home_buf) orelse return null;
        const rels = [_][]const u8{
            ".steam/sdk64/steamclient.so",
            ".local/share/Steam/linux64/steamclient.so",
            ".steam/steam/linux64/steamclient.so",
            ".steam/root/linux64/steamclient.so",
            ".steam/debian-installation/linux64/steamclient.so",
            ".var/app/com.valvesoftware.Steam/.steam/sdk64/steamclient.so",
            ".var/app/com.valvesoftware.Steam/.local/share/Steam/linux64/steamclient.so",
            ".var/app/com.valvesoftware.Steam/.steam/steam/linux64/steamclient.so",
            "snap/steam/common/.steam/sdk64/steamclient.so",
            "snap/steam/common/.local/share/Steam/linux64/steamclient.so",
            "snap/steam/common/.steam/steam/linux64/steamclient.so",
        };
        for (rels) |rel| {
            const p = bufPrintZ(buf, "{s}/{s}", .{ home, rel }) catch continue;
            if (fileExists(p.ptr)) return p;
        }
        if (fileExists("/usr/lib/steam/linux64/steamclient.so")) {
            return bufPrintZ(buf, "/usr/lib/steam/linux64/steamclient.so", .{}) catch null;
        }
        return null;
    }
}

/// Extracts the next value for `target_key` (e.g. `"path"` or `"installdir"`) from a Valve VDF/ACF file.
pub fn nextVdfKeyValue(content: []const u8, target_key: []const u8, cursor: *usize, out_buf: []u8) ?[]const u8 {
    while (cursor.* < content.len) {
        const start = cursor.*;
        const line_rel_end = std.mem.indexOfScalar(u8, content[start..], '\n') orelse (content.len - start);
        const line = std.mem.trim(u8, content[start .. start + line_rel_end], " \t\r");
        cursor.* = start + line_rel_end + @as(usize, if (start + line_rel_end < content.len) 1 else 0);

        if (line.len < 6 or line[0] != '"') continue;
        const key_end = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse continue;
        const key = line[1..key_end];
        if (!std.ascii.eqlIgnoreCase(key, target_key)) continue;

        const rest = std.mem.trimStart(u8, line[key_end + 1 ..], " \t");
        if (rest.len < 2 or rest[0] != '"') continue;

        var out_len: usize = 0;
        var i: usize = 1;
        while (i < rest.len) : (i += 1) {
            const ch = rest[i];
            if (ch == '\\' and i + 1 < rest.len) {
                i += 1;
                if (out_len < out_buf.len) {
                    out_buf[out_len] = rest[i];
                    out_len += 1;
                }
                continue;
            }
            if (ch == '"') {
                if (out_len > 0) return out_buf[0..out_len];
                break;
            }
            if (out_len < out_buf.len) {
                out_buf[out_len] = ch;
                out_len += 1;
            }
        }
    }
    return null;
}

pub fn nextVdfPathValue(content: []const u8, cursor: *usize, out_buf: []u8) ?[]const u8 {
    return nextVdfKeyValue(content, "path", cursor, out_buf);
}

fn eu5ActivityMtime(dir_path: []const u8) ?i64 {
    const sep = if (builtin.os.tag == .windows) "\\" else "/";
    const files = [_][]const u8{
        "logs/debug.log",
        "logs/game.log",
        "logs/multiplayer.log",
        "continue_game.json",
    };
    var best: ?i64 = null;
    var pbuf: [768]u8 = undefined;
    for (files) |rel| {
        const p = if (builtin.os.tag == .windows) blk: {
            var rel_win: [64]u8 = undefined;
            for (rel, 0..) |ch, idx| rel_win[idx] = if (ch == '/') '\\' else ch;
            break :blk bufPrintZ(&pbuf, "{s}{s}{s}", .{ dir_path, sep, rel_win[0..rel.len] }) catch continue;
        } else bufPrintZ(&pbuf, "{s}{s}{s}", .{ dir_path, sep, rel }) catch continue;

        if (fileMtime(p.ptr)) |mt| {
            if (best == null or mt > best.?) best = mt;
        }
    }
    return best;
}

const DirBest = struct {
    best_log_buf: [768]u8 = undefined,
    best_log_len: usize = 0,
    best_log_mtime: i64 = -1,
    fallback_buf: [768]u8 = undefined,
    fallback_len: usize = 0,

    fn consider(self: *DirBest, cand: [:0]const u8) void {
        if (!dirExists(cand.ptr)) return;
        if (eu5ActivityMtime(cand)) |mtime| {
            if (cand.len < self.best_log_buf.len and (self.best_log_len == 0 or mtime > self.best_log_mtime)) {
                @memcpy(self.best_log_buf[0..cand.len], cand);
                self.best_log_buf[cand.len] = 0;
                self.best_log_len = cand.len;
                self.best_log_mtime = mtime;
            }
            return;
        }
        if (self.fallback_len == 0 and cand.len < self.fallback_buf.len) {
            @memcpy(self.fallback_buf[0..cand.len], cand);
            self.fallback_buf[cand.len] = 0;
            self.fallback_len = cand.len;
        }
    }

    fn finish(self: *const DirBest, out_buf: []u8) ?[]const u8 {
        if (self.best_log_len > 0 and self.best_log_len < out_buf.len) {
            @memcpy(out_buf[0..self.best_log_len], self.best_log_buf[0..self.best_log_len]);
            out_buf[self.best_log_len] = 0;
            return out_buf[0..self.best_log_len];
        }
        if (self.fallback_len > 0 and self.fallback_len < out_buf.len) {
            @memcpy(out_buf[0..self.fallback_len], self.fallback_buf[0..self.fallback_len]);
            out_buf[self.fallback_len] = 0;
            return out_buf[0..self.fallback_len];
        }
        return null;
    }
};

fn considerWinePrefixUsers(best: *DirBest, prefix_dir: []const u8, linux_user: ?[]const u8) void {
    var cand_buf: [768]u8 = undefined;
    if (bufPrintZ(&cand_buf, "{s}/drive_c/users/steamuser/Documents/Paradox Interactive/Europa Universalis V", .{prefix_dir})) |c| {
        best.consider(c);
    } else |_| {}
    if (linux_user) |u| {
        if (u.len > 0 and !std.mem.eql(u8, u, "steamuser")) {
            if (bufPrintZ(&cand_buf, "{s}/drive_c/users/{s}/Documents/Paradox Interactive/Europa Universalis V", .{ prefix_dir, u })) |c| {
                best.consider(c);
            } else |_| {}
        }
    }
}

fn considerSteamRootLinux(best: *DirBest, steam_root: []const u8, linux_user: ?[]const u8) void {
    var root_z_buf: [600]u8 = undefined;
    const root_z = bufPrintZ(&root_z_buf, "{s}", .{steam_root}) catch return;
    if (!dirExists(root_z.ptr)) return;

    var pfx_buf: [640]u8 = undefined;
    if (bufPrintZ(&pfx_buf, "{s}/steamapps/compatdata/{s}/pfx", .{ steam_root, root.EU5_STEAM_APP_ID })) |pfx| {
        considerWinePrefixUsers(best, pfx, linux_user);
    } else |_| {}

    const vdf_rels = [_][]const u8{
        "steamapps/libraryfolders.vdf",
        "config/libraryfolders.vdf",
    };
    var vdf_path_buf: [640]u8 = undefined;
    var vdf_data: [32768]u8 = undefined;
    var lib_path_buf: [600]u8 = undefined;

    for (vdf_rels) |vdf_rel| {
        const vdf_path = bufPrintZ(&vdf_path_buf, "{s}/{s}", .{ steam_root, vdf_rel }) catch continue;
        const n = readFileRange(vdf_path.ptr, 0, &vdf_data) orelse continue;
        if (n == 0) continue;

        var cursor: usize = 0;
        while (nextVdfPathValue(vdf_data[0..n], &cursor, &lib_path_buf)) |lib_raw| {
            const lib = std.mem.trimEnd(u8, lib_raw, "/");
            if (lib.len == 0) continue;
            if (bufPrintZ(&pfx_buf, "{s}/steamapps/compatdata/{s}/pfx", .{ lib, root.EU5_STEAM_APP_ID })) |pfx| {
                considerWinePrefixUsers(best, pfx, linux_user);
            } else |_| {}
        }
    }
}

/// Selects the best Proton/Wine EU5 user data directory from a slice of Steam library roots.
pub fn pickBestProtonUserDataDir(library_paths: []const []const u8, out_buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    var best = DirBest{};
    var pfx_buf: [640]u8 = undefined;
    var user_buf: [128]u8 = undefined;
    const linux_user = getEnvUtf8("USER", &user_buf);

    for (library_paths) |lib_raw| {
        const lib = std.mem.trimEnd(u8, lib_raw, "/");
        if (lib.len == 0) continue;
        const pfx = bufPrintZ(&pfx_buf, "{s}/steamapps/compatdata/{s}/pfx", .{ lib, root.EU5_STEAM_APP_ID }) catch continue;
        considerWinePrefixUsers(&best, pfx, linux_user);
    }
    return best.finish(out_buf);
}

pub fn findEu5UserDataDir(override: ?[]const u8, buf: []u8) ?[]const u8 {
    if (override) |ov| {
        const trimmed = std.mem.trim(u8, ov, " \t\r\n");
        if (trimmed.len > 0) {
            if (bufPrintZ(buf, "{s}", .{trimmed})) |p| {
                if (dirExists(p.ptr)) return p;
            } else |_| {}
        }
    }

    if (builtin.os.tag == .windows) {
        var best = DirBest{};
        var cand_buf: [768]u8 = undefined;

        // 1. Windows Known Folder (automatically resolves OneDrive & localized Documents names)
        var docs_w: [512]u16 = std.mem.zeroes([512]u16);
        if (win.SHGetFolderPathW(null, win.CSIDL_PERSONAL, null, 0, &docs_w) == 0) {
            var docs_u8: [512]u8 = undefined;
            if (utf16ToUtf8(docs_w[0..utf16Len(@ptrCast(&docs_w))], &docs_u8)) |docs_slice| {
                if (bufPrintZ(&cand_buf, "{s}\\Paradox Interactive\\Europa Universalis V", .{docs_slice})) |p| {
                    best.consider(p);
                } else |_| {}
            }
        }

        // 2. Registry User Shell Folders ("Personal") fallback
        var reg_docs: [512]u8 = undefined;
        if (readWinRegString(
            win.HKEY_CURRENT_USER,
            "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders",
            "Personal",
            &reg_docs,
        )) |docs_slice| {
            const norm = normalizeWinPathInPlace(&reg_docs, docs_slice.len);
            if (bufPrintZ(&cand_buf, "{s}\\Paradox Interactive\\Europa Universalis V", .{norm})) |p| {
                best.consider(p);
            } else |_| {}
        }

        // 3. USERPROFILE OneDrive / Documents fallbacks
        var home_buf: [512]u8 = undefined;
        if (getEnvUtf8("USERPROFILE", &home_buf)) |home| {
            const cands = [_][]const u8{
                "OneDrive\\Documents\\Paradox Interactive\\Europa Universalis V",
                "Documents\\Paradox Interactive\\Europa Universalis V",
            };
            for (cands) |rel| {
                if (bufPrintZ(&cand_buf, "{s}\\{s}", .{ home, rel })) |p| {
                    best.consider(p);
                } else |_| {}
            }
        }
        return best.finish(buf);
    } else {
        var cand_buf: [768]u8 = undefined;
        var best = DirBest{};
        var env_buf: [512]u8 = undefined;
        var user_buf: [128]u8 = undefined;
        const linux_user = getEnvUtf8("USER", &user_buf);

        // 1. Explicit XDG_DATA_HOME (native Linux & custom Steam data root)
        if (getEnvUtf8("XDG_DATA_HOME", &env_buf)) |xdg_raw| {
            const xdg = std.mem.trimEnd(u8, xdg_raw, "/");
            if (xdg.len > 0) {
                if (bufPrintZ(&cand_buf, "{s}/Paradox Interactive/Europa Universalis V", .{xdg})) |cand| {
                    best.consider(cand);
                } else |_| {}
                if (bufPrintZ(&cand_buf, "{s}/Steam", .{xdg})) |sroot| {
                    considerSteamRootLinux(&best, sroot, linux_user);
                } else |_| {}
            }
        }

        // 2. Explicit Proton / Wine environment overrides
        if (getEnvUtf8("STEAM_COMPAT_DATA_PATH", &env_buf)) |compat_raw| {
            const compat = std.mem.trimEnd(u8, compat_raw, "/");
            if (compat.len > 0) {
                if (bufPrintZ(&cand_buf, "{s}/pfx", .{compat})) |pfx| {
                    considerWinePrefixUsers(&best, pfx, linux_user);
                } else |_| {}
            }
        }
        if (getEnvUtf8("WINEPREFIX", &env_buf)) |wp_raw| {
            const wp = std.mem.trimEnd(u8, wp_raw, "/");
            if (wp.len > 0) {
                considerWinePrefixUsers(&best, wp, linux_user);
            }
        }
        if (getEnvUtf8("STEAM_COMPAT_CLIENT_INSTALL_PATH", &env_buf)) |sc_raw| {
            const sc = std.mem.trimEnd(u8, sc_raw, "/");
            if (sc.len > 0) {
                considerSteamRootLinux(&best, sc, linux_user);
            }
        }

        var home_buf: [512]u8 = undefined;
        const home = getEnvUtf8("HOME", &home_buf) orelse return best.finish(buf);

        // 3. Steam Proton prefixes across standard, Debian, Flatpak, and Snap Steam roots + all libraryfolders.vdf drives
        const steam_roots = [_][]const u8{
            ".local/share/Steam",
            ".steam/steam",
            ".steam/root",
            ".steam/debian-installation",
            ".var/app/com.valvesoftware.Steam/.local/share/Steam",
            ".var/app/com.valvesoftware.Steam/.steam/steam",
            "snap/steam/common/.local/share/Steam",
            "snap/steam/common/.steam/steam",
        };
        var root_buf: [600]u8 = undefined;
        for (steam_roots) |root_rel| {
            const steam_root = bufPrintZ(&root_buf, "{s}/{s}", .{ home, root_rel }) catch continue;
            considerSteamRootLinux(&best, steam_root, linux_user);
        }

        // 4. Native Linux Paradox user data directories (standard, legacy, Flatpak, Snap, Documents)
        const native_rels = [_][]const u8{
            ".local/share/Paradox Interactive/Europa Universalis V",
            ".paradoxinteractive/Europa Universalis V",
            ".var/app/com.valvesoftware.Steam/.local/share/Paradox Interactive/Europa Universalis V",
            "snap/steam/common/.local/share/Paradox Interactive/Europa Universalis V",
            "Documents/Paradox Interactive/Europa Universalis V",
        };
        for (native_rels) |rel| {
            const cand = bufPrintZ(&cand_buf, "{s}/{s}", .{ home, rel }) catch continue;
            best.consider(cand);
        }

        return best.finish(buf);
    }
}

fn checkLibraryForGameInstall(lib_path: []const u8, out_buf: []u8) ?[]const u8 {
    const sep = if (builtin.os.tag == .windows) "\\" else "/";
    const lib = std.mem.trimEnd(u8, lib_path, "/\\");
    if (lib.len == 0) return null;

    var manifest_buf: [640]u8 = undefined;
    const manifest_path = bufPrintZ(&manifest_buf, "{s}{s}steamapps{s}appmanifest_{s}.acf", .{
        lib, sep, sep, root.EU5_STEAM_APP_ID,
    }) catch return null;

    var mdata: [16384]u8 = undefined;
    const n = readFileRange(manifest_path.ptr, 0, &mdata) orelse return null;
    if (n == 0) return null;

    var cursor: usize = 0;
    var install_dir_buf: [256]u8 = undefined;
    const install_dir = nextVdfKeyValue(mdata[0..n], "installdir", &cursor, &install_dir_buf) orelse return null;

    const game_path = bufPrintZ(out_buf, "{s}{s}steamapps{s}common{s}{s}", .{
        lib, sep, sep, sep, install_dir,
    }) catch return null;
    return if (dirExists(game_path.ptr)) game_path else null;
}

fn searchSteamRootForGameInstall(steam_root: []const u8, out_buf: []u8) ?[]const u8 {
    var root_z_buf: [600]u8 = undefined;
    const root_z = bufPrintZ(&root_z_buf, "{s}", .{steam_root}) catch return null;
    if (!dirExists(root_z.ptr)) return null;

    if (checkLibraryForGameInstall(steam_root, out_buf)) |found| return found;

    const sep = if (builtin.os.tag == .windows) "\\" else "/";
    const vdf_rels = [_][]const u8{
        "steamapps",
        "config",
    };
    var vdf_path_buf: [640]u8 = undefined;
    var vdf_data: [32768]u8 = undefined;
    var lib_path_buf: [600]u8 = undefined;

    for (vdf_rels) |sub| {
        const vdf_path = bufPrintZ(&vdf_path_buf, "{s}{s}{s}{s}libraryfolders.vdf", .{ steam_root, sep, sub, sep }) catch continue;
        const n = readFileRange(vdf_path.ptr, 0, &vdf_data) orelse continue;
        if (n == 0) continue;

        var cursor: usize = 0;
        while (nextVdfPathValue(vdf_data[0..n], &cursor, &lib_path_buf)) |lib_raw| {
            if (checkLibraryForGameInstall(lib_raw, out_buf)) |found| return found;
        }
    }
    return null;
}

/// Locates the installed Europa Universalis V directory across Steam libraries for CountryLookup.
pub fn findEu5GameInstallDir(out_buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        var root_buf: [512]u8 = undefined;
        const steam_root = findSteamRoot(&root_buf) orelse return null;
        return searchSteamRootForGameInstall(steam_root, out_buf);
    } else {
        var env_buf: [512]u8 = undefined;
        if (getEnvUtf8("STEAM_COMPAT_CLIENT_INSTALL_PATH", &env_buf)) |sc| {
            if (searchSteamRootForGameInstall(std.mem.trimEnd(u8, sc, "/"), out_buf)) |found| return found;
        }
        if (getEnvUtf8("XDG_DATA_HOME", &env_buf)) |xdg| {
            var sbuf: [600]u8 = undefined;
            if (bufPrintZ(&sbuf, "{s}/Steam", .{std.mem.trimEnd(u8, xdg, "/")})) |sr| {
                if (searchSteamRootForGameInstall(sr, out_buf)) |found| return found;
            } else |_| {}
        }
        var home_buf: [512]u8 = undefined;
        const home = getEnvUtf8("HOME", &home_buf) orelse return null;
        const steam_roots = [_][]const u8{
            ".local/share/Steam",
            ".steam/steam",
            ".steam/root",
            ".steam/debian-installation",
            ".var/app/com.valvesoftware.Steam/.local/share/Steam",
            ".var/app/com.valvesoftware.Steam/.steam/steam",
            "snap/steam/common/.local/share/Steam",
            "snap/steam/common/.steam/steam",
        };
        var root_buf: [600]u8 = undefined;
        for (steam_roots) |root_rel| {
            const steam_root = bufPrintZ(&root_buf, "{s}/{s}", .{ home, root_rel }) catch continue;
            if (searchSteamRootForGameInstall(steam_root, out_buf)) |found| return found;
        }
        return null;
    }
}

pub fn launchEu5ViaSteam() void {
    if (builtin.os.tag == .windows) {
        var root_buf: [512]u8 = undefined;
        const steam_root = findSteamRoot(&root_buf) orelse return;
        var cmd_buf: [640]u8 = undefined;
        const cmd = bufPrintZ(&cmd_buf, "\"{s}\\steam.exe\" -applaunch {s}", .{ steam_root, root.EU5_STEAM_APP_ID }) catch return;
        var cmd_w: [700]u16 = undefined;
        const cw = utf8ToUtf16Z(cmd, &cmd_w) orelse return;
        var si = std.mem.zeroes(win.STARTUPINFOW);
        si.cb = @sizeOf(win.STARTUPINFOW);
        var pi = std.mem.zeroes(win.PROCESS_INFORMATION);
        if (win.CreateProcessW(null, @constCast(cw.ptr), null, null, 0, 0, null, null, &si, &pi) != 0) {
            _ = win.CloseHandle(pi.hProcess);
            _ = win.CloseHandle(pi.hThread);
        }
    } else {
        const pid = posix.fork();
        if (pid == 0) {
            const pid2 = posix.fork();
            if (pid2 == 0) {
                // 1. Standard Steam in PATH (Arch, Fedora, Ubuntu, Debian, openSUSE, NixOS, SteamOS, etc.)
                const argv_steam = [_:null]?[*:0]const u8{ "steam", "-applaunch", root.EU5_STEAM_APP_ID };
                _ = posix.execvp("steam", &argv_steam);

                // 2. Local Steam shell launcher fallbacks
                var home_buf: [512]u8 = undefined;
                if (getEnvUtf8("HOME", &home_buf)) |home| {
                    var sh_buf: [600]u8 = undefined;
                    const sh_rels = [_][]const u8{ ".local/share/Steam/steam.sh", ".steam/steam.sh" };
                    for (sh_rels) |rel| {
                        if (bufPrintZ(&sh_buf, "{s}/{s}", .{ home, rel })) |sh_path| {
                            if (fileExists(sh_path.ptr)) {
                                const argv_sh = [_:null]?[*:0]const u8{ sh_path.ptr, "-applaunch", root.EU5_STEAM_APP_ID };
                                _ = posix.execvp(sh_path.ptr, &argv_sh);
                            }
                        } else |_| {}
                    }
                }

                // 3. Flatpak Steam (Bazzite, Fedora Silverblue, KDE/GNOME Flatpak setups)
                const argv_flatpak = [_:null]?[*:0]const u8{
                    "flatpak",
                    "run",
                    "com.valvesoftware.Steam",
                    "-applaunch",
                    root.EU5_STEAM_APP_ID,
                };
                _ = posix.execvp("flatpak", &argv_flatpak);

                // 4. Desktop-agnostic XDG URI handler fallback (KDE, GNOME, XFCE, Wayland WMs)
                const argv_xdg = [_:null]?[*:0]const u8{ "xdg-open", "steam://rungameid/" ++ root.EU5_STEAM_APP_ID };
                _ = posix.execvp("xdg-open", &argv_xdg);

                posix._exit(1);
            }
            posix._exit(0);
        } else if (pid > 0) {
            var status: c_int = 0;
            _ = posix.waitpid(pid, &status, 0);
        }
    }
}

/// Spawns a custom game command (used by `--launch-with-command -- <cmd>`).
pub fn spawnCustomCommand(alloc: std.mem.Allocator, cmd_args: []const [:0]const u8, wait_for_exit: bool) void {
    if (cmd_args.len == 0) return;
    if (builtin.os.tag == .windows) {
        var cmd_line = std.ArrayList(u8).empty;
        defer cmd_line.deinit(alloc);

        for (cmd_args, 0..) |arg, idx| {
            if (idx > 0) cmd_line.append(alloc, ' ') catch return;
            const needs_quote = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\"") != null;
            if (needs_quote) cmd_line.append(alloc, '"') catch return;
            for (arg) |ch| {
                if (ch == '"') cmd_line.append(alloc, '\\') catch return;
                cmd_line.append(alloc, ch) catch return;
            }
            if (needs_quote) cmd_line.append(alloc, '"') catch return;
        }

        const cmd_w = alloc.alloc(u16, cmd_line.items.len * 2 + 2) catch return;
        defer alloc.free(cmd_w);
        const cw = utf8ToUtf16Z(cmd_line.items, cmd_w) orelse return;

        var si = std.mem.zeroes(win.STARTUPINFOW);
        si.cb = @sizeOf(win.STARTUPINFOW);
        var pi = std.mem.zeroes(win.PROCESS_INFORMATION);
        if (win.CreateProcessW(null, @constCast(cw.ptr), null, null, 0, 0, null, null, &si, &pi) != 0) {
            if (wait_for_exit) {
                _ = win.WaitForSingleObject(pi.hProcess, win.INFINITE);
            }
            _ = win.CloseHandle(pi.hProcess);
            _ = win.CloseHandle(pi.hThread);
        }
    } else {
        const argv = alloc.allocSentinel(?[*:0]const u8, cmd_args.len, null) catch return;
        defer alloc.free(argv);
        for (cmd_args, 0..) |a, i| argv[i] = a.ptr;

        const pid = posix.fork();
        if (pid == 0) {
            if (wait_for_exit) {
                _ = posix.execvp(cmd_args[0].ptr, argv.ptr);
                posix._exit(127);
            } else {
                const pid2 = posix.fork();
                if (pid2 == 0) {
                    _ = posix.execvp(cmd_args[0].ptr, argv.ptr);
                    posix._exit(127);
                }
                posix._exit(0);
            }
        } else if (pid > 0) {
            var status: c_int = 0;
            _ = posix.waitpid(pid, &status, 0);
        }
    }
}

test "extracts Linux and Windows library paths and installdir from Steam VDF/ACF files" {
    const vdf =
        "\"libraryfolders\"\n" ++
        "{\n" ++
        "\t\"0\"\n" ++
        "\t{\n" ++
        "\t\t\"path\"\t\t\"/mnt/primary/Steam\"\n" ++
        "\t}\n" ++
        "\t\"1\"\n" ++
        "\t{\n" ++
        "\t\t\"path\"\t\t\"/media/games/Steam Library\"\n" ++
        "\t}\n" ++
        "\t\"2\"\n" ++
        "\t{\n" ++
        "\t\t\"path\"\t\t\"D:\\\\Games\\\\SteamLibrary\"\n" ++
        "\t}\n" ++
        "}\n";
    var cursor: usize = 0;
    var out: [256]u8 = undefined;

    try std.testing.expectEqualStrings("/mnt/primary/Steam", nextVdfPathValue(vdf, &cursor, &out).?);
    try std.testing.expectEqualStrings("/media/games/Steam Library", nextVdfPathValue(vdf, &cursor, &out).?);
    try std.testing.expectEqualStrings("D:\\Games\\SteamLibrary", nextVdfPathValue(vdf, &cursor, &out).?);
    try std.testing.expectEqual(@as(?[]const u8, null), nextVdfPathValue(vdf, &cursor, &out));

    const acf =
        "\"AppState\"\n" ++
        "{\n" ++
        "\t\"appid\"\t\t\"3450310\"\n" ++
        "\t\"installdir\"\t\t\"Europa Universalis V\"\n" ++
        "}\n";
    cursor = 0;
    try std.testing.expectEqualStrings("Europa Universalis V", nextVdfKeyValue(acf, "installdir", &cursor, &out).?);
}

test "prioritizes existing Proton user data directory across multiple Steam libraries" {
    if (builtin.os.tag == .windows) return;
    var base_buf: [256]u8 = undefined;
    const base = bufPrintZ(&base_buf, "/tmp/eu5-rpc-test-proton-{d}", .{std.os.linux.getpid()}) catch unreachable;
    var empty_buf: [320]u8 = undefined;
    var games_buf: [320]u8 = undefined;
    var docs_buf: [512]u8 = undefined;
    const lib_empty = bufPrintZ(&empty_buf, "{s}/SteamEmpty", .{base}) catch unreachable;
    const lib_games = bufPrintZ(&games_buf, "{s}/SteamGames", .{base}) catch unreachable;
    const proton_docs = bufPrintZ(&docs_buf, "{s}/steamapps/compatdata/3450310/pfx/drive_c/users/steamuser/Documents/Paradox Interactive/Europa Universalis V", .{lib_games}) catch unreachable;

    ensureDirRecursive(lib_empty);
    ensureDirRecursive(proton_docs);

    const libs = [_][]const u8{ lib_empty, lib_games };
    var out: [512]u8 = undefined;
    const picked = pickBestProtonUserDataDir(&libs, &out).?;
    try std.testing.expectEqualStrings(proton_docs, picked);
}
