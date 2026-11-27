// SPDX-License-Identifier: GPL-3.0-only
// 100% Pure Zig Auto-Updater & Legacy Ruby -> Zig Migrator for EU5 RPC.
// - Queries GitHub's latest release API (https://api.github.com/repos/buntatoes/eu5-rpc/releases/latest)
//   using Zig's built-in std.http.Client (pure Zig TLS, zero external runtime dependencies).
// - Detects legacy Ruby installations (lib/eu5_rpc.rb, bin/eu5-rpc, or Eu5RpcRuby registry key)
//   and migrates them cleanly to the latest native Zig release while preserving config.toml.
// - On Windows: downloads EU5-RPC-Setup-*-win64.exe, atomically renames the running exe to .old,
//   runs the silent Zig installer, and relaunches the updated binary.
// - On Linux: downloads eu5-rpc-linux-x86_64.tar.gz, extracts the ELF binary in pure Zig using
//   std.compress.flate + USTAR parsing, atomically replaces the binary, and cleans legacy Ruby files.
const std = @import("std");
const builtin = @import("builtin");
const eu5_files = @import("eu5_files.zig");
const root = @import("root.zig");

pub const GITHUB_LATEST_API_URL = "https://api.github.com/repos/buntatoes/eu5-rpc/releases/latest";
pub const GITHUB_LATEST_PAGE_URL = "https://github.com/buntatoes/eu5-rpc/releases/latest";

const win = if (builtin.os.tag == .windows) struct {
    const HKEY = ?*anyopaque;
    const HANDLE = ?*anyopaque;
    const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
    const KEY_READ: u32 = 0x20019;
    const ERROR_SUCCESS: i32 = 0;
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    const INFINITE: u32 = 0xFFFFFFFF;

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

    extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;
    extern "kernel32" fn MoveFileExW(lpExistingFileName: [*:0]const u16, lpNewFileName: ?[*:0]const u16, dwFlags: u32) callconv(.winapi) i32;
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
    extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;
} else struct {};

const posix = if (builtin.os.tag != .windows) struct {
    const DIR = anyopaque;
    const Dirent = extern struct {
        d_ino: u64,
        d_off: i64,
        d_reclen: u16,
        d_type: u8,
        d_name: [256]u8,
    };
    extern "c" fn readlink(pathname: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;
    extern "c" fn chmod(pathname: [*:0]const u8, mode: u32) c_int;
    extern "c" fn rename(oldpath: [*:0]const u8, newpath: [*:0]const u8) c_int;
    extern "c" fn unlink(pathname: [*:0]const u8) c_int;
    extern "c" fn rmdir(pathname: [*:0]const u8) c_int;
    extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
    extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
    extern "c" fn readdir(dirp: *DIR) ?*Dirent;
    extern "c" fn closedir(dirp: *DIR) c_int;
    extern "c" fn getuid() u32;
    extern "c" fn fork() c_int;
    extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
    extern "c" fn _exit(status: c_int) noreturn;
} else struct {};

pub const SemVer = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,

    pub fn parse(raw: []const u8) ?SemVer {
        var s = std.mem.trim(u8, raw, " \t\r\n");
        if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
        if (std.mem.indexOfAny(u8, s, "-+")) |cut| s = s[0..cut];
        if (s.len == 0) return null;

        var it = std.mem.splitScalar(u8, s, '.');
        const maj_s = it.next() orelse return null;
        const maj = std.fmt.parseInt(u32, maj_s, 10) catch return null;
        const min = if (it.next()) |ms| (std.fmt.parseInt(u32, ms, 10) catch return null) else 0;
        const pat = if (it.next()) |ps| (std.fmt.parseInt(u32, ps, 10) catch return null) else 0;
        return .{ .major = maj, .minor = min, .patch = pat };
    }

    pub fn isNewerThan(self: SemVer, other: SemVer) bool {
        if (self.major != other.major) return self.major > other.major;
        if (self.minor != other.minor) return self.minor > other.minor;
        return self.patch > other.patch;
    }
};

pub const ReleaseInfo = struct {
    tag_buf: [64]u8 = undefined,
    tag_len: usize = 0,
    version: SemVer = .{},
    html_url_buf: [256]u8 = undefined,
    html_url_len: usize = 0,
    win_url_buf: [512]u8 = undefined,
    win_url_len: usize = 0,
    linux_url_buf: [512]u8 = undefined,
    linux_url_len: usize = 0,
    is_prerelease: bool = false,
    is_draft: bool = false,

    pub fn tagName(self: *const ReleaseInfo) []const u8 {
        return self.tag_buf[0..self.tag_len];
    }

    pub fn htmlUrl(self: *const ReleaseInfo) []const u8 {
        return if (self.html_url_len > 0) self.html_url_buf[0..self.html_url_len] else GITHUB_LATEST_PAGE_URL;
    }

    pub fn winAssetUrl(self: *const ReleaseInfo) ?[]const u8 {
        return if (self.win_url_len > 0) self.win_url_buf[0..self.win_url_len] else null;
    }

    pub fn linuxAssetUrl(self: *const ReleaseInfo) ?[]const u8 {
        return if (self.linux_url_len > 0) self.linux_url_buf[0..self.linux_url_len] else null;
    }
};

pub const UpdateStatus = enum {
    up_to_date,
    update_available,
    migrating_from_ruby,
    updated_restart_required,
    check_failed,
    apply_failed,
};

pub const CheckResult = struct {
    status: UpdateStatus,
    release: ?ReleaseInfo = null,
    legacy_ruby_detected: bool = false,
};

pub fn isTrustedDownloadUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://github.com/buntatoes/eu5-rpc/") or
        std.mem.startsWith(u8, url, "https://objects.githubusercontent.com/") or
        std.mem.startsWith(u8, url, "https://release-assets.githubusercontent.com/");
}

fn findJsonBool(json: []const u8, key: []const u8) ?bool {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, json, pos, needle)) |idx| {
        var j = idx + needle.len;
        while (j < json.len and (json[j] == ' ' or json[j] == '\t' or json[j] == '\r' or json[j] == '\n')) : (j += 1) {}
        if (j < json.len and json[j] == ':') {
            j += 1;
            while (j < json.len and (json[j] == ' ' or json[j] == '\t' or json[j] == '\r' or json[j] == '\n')) : (j += 1) {}
            if (std.mem.startsWith(u8, json[j..], "true")) return true;
            if (std.mem.startsWith(u8, json[j..], "false")) return false;
        }
        pos = idx + needle.len;
    }
    return null;
}

fn nextJsonStringForKey(json: []const u8, key: []const u8, cursor: *usize, out_buf: []u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    while (cursor.* < json.len) {
        const idx = std.mem.indexOfPos(u8, json, cursor.*, needle) orelse {
            cursor.* = json.len;
            return null;
        };
        var j = idx + needle.len;
        while (j < json.len and (json[j] == ' ' or json[j] == '\t' or json[j] == '\r' or json[j] == '\n')) : (j += 1) {}
        if (j >= json.len or json[j] != ':') {
            cursor.* = idx + needle.len;
            continue;
        }
        j += 1;
        while (j < json.len and (json[j] == ' ' or json[j] == '\t' or json[j] == '\r' or json[j] == '\n')) : (j += 1) {}
        if (j >= json.len or json[j] != '"') {
            cursor.* = j;
            continue;
        }
        j += 1;

        var out_len: usize = 0;
        while (j < json.len) : (j += 1) {
            if (json[j] == '\\' and j + 1 < json.len) {
                j += 1;
                if (out_len < out_buf.len) {
                    out_buf[out_len] = json[j];
                    out_len += 1;
                }
                continue;
            }
            if (json[j] == '"') {
                cursor.* = j + 1;
                return out_buf[0..out_len];
            }
            if (out_len < out_buf.len) {
                out_buf[out_len] = json[j];
                out_len += 1;
            }
        }
        cursor.* = json.len;
        return null;
    }
    return null;
}

/// Parses GitHub `/releases/latest` JSON payload into `ReleaseInfo`.
pub fn parseLatestReleaseJson(json: []const u8) ?ReleaseInfo {
    var info = ReleaseInfo{};
    var cur: usize = 0;
    const tag = nextJsonStringForKey(json, "tag_name", &cur, &info.tag_buf) orelse return null;
    info.tag_len = tag.len;
    info.version = SemVer.parse(tag) orelse return null;

    info.is_draft = findJsonBool(json, "draft") orelse false;
    info.is_prerelease = findJsonBool(json, "prerelease") orelse false;

    cur = 0;
    if (nextJsonStringForKey(json, "html_url", &cur, &info.html_url_buf)) |hu| {
        info.html_url_len = hu.len;
    }

    cur = 0;
    var url_buf: [512]u8 = undefined;
    while (nextJsonStringForKey(json, "browser_download_url", &cur, &url_buf)) |dl_url| {
        if (!isTrustedDownloadUrl(dl_url)) continue;
        if (std.ascii.endsWithIgnoreCase(dl_url, "-win64.exe") or std.ascii.endsWithIgnoreCase(dl_url, ".exe")) {
            if (info.win_url_len == 0) {
                @memcpy(info.win_url_buf[0..dl_url.len], dl_url);
                info.win_url_len = dl_url.len;
            }
        } else if (std.ascii.endsWithIgnoreCase(dl_url, ".tar.gz")) {
            if (info.linux_url_len == 0) {
                @memcpy(info.linux_url_buf[0..dl_url.len], dl_url);
                info.linux_url_len = dl_url.len;
            }
        }
    }

    return info;
}

/// Detects whether a legacy Ruby EU5 RPC installation (`v0.1`–`v0.3.3`) is still present on this machine.
pub fn detectLegacyRubyInstall() bool {
    if (builtin.os.tag == .windows) {
        // 1. Check legacy Ruby uninstall registry key
        const legacy_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Eu5RpcRuby");
        var hkey: win.HKEY = null;
        if (win.RegOpenKeyExW(win.HKEY_CURRENT_USER, legacy_key.ptr, 0, win.KEY_READ, &hkey) == win.ERROR_SUCCESS) {
            _ = win.RegCloseKey(hkey);
            return true;
        }
        // 2. Check %LOCALAPPDATA%\EU5-RPC\lib\eu5_rpc.rb and exe directory
        var env_buf: [512]u8 = undefined;
        var p_buf: [640]u8 = undefined;
        if (eu5_files.getEnvUtf8("LOCALAPPDATA", &env_buf)) |la| {
            if (root.bufPrintZ(&p_buf, "{s}\\EU5-RPC\\lib\\eu5_rpc.rb", .{la})) |p| {
                if (eu5_files.fileExists(p.ptr)) return true;
            } else |_| {}
        }
        var mod_buf: [512]u8 = undefined;
        if (eu5_files.getModuleDirUtf8(&mod_buf)) |md| {
            if (root.bufPrintZ(&p_buf, "{s}\\lib\\eu5_rpc.rb", .{md})) |p| {
                if (eu5_files.fileExists(p.ptr)) return true;
            } else |_| {}
        }
        return false;
    } else {
        var env_buf: [512]u8 = undefined;
        var p_buf: [640]u8 = undefined;
        if (eu5_files.getEnvUtf8("XDG_DATA_HOME", &env_buf)) |xdg| {
            const x = std.mem.trimEnd(u8, xdg, "/");
            if (root.bufPrintZ(&p_buf, "{s}/eu5-rpc/lib/eu5_rpc.rb", .{x})) |p| {
                if (eu5_files.fileExists(p.ptr)) return true;
            } else |_| {}
        }
        if (eu5_files.getEnvUtf8("HOME", &env_buf)) |home| {
            const h = std.mem.trimEnd(u8, home, "/");
            const rels = [_][]const u8{
                ".local/share/eu5-rpc/lib/eu5_rpc.rb",
                ".local/share/eu5-rpc/bin/eu5-rpc",
            };
            for (rels) |rel| {
                if (root.bufPrintZ(&p_buf, "{s}/{s}", .{ h, rel })) |p| {
                    if (eu5_files.fileExists(p.ptr)) return true;
                } else |_| {}
            }
        }
        return false;
    }
}

/// Removes stale `eu5-rpc.exe.old` left over after a Windows self-update.
pub fn cleanupOldBinary() void {
    if (builtin.os.tag != .windows) return;
    var wbuf: [1024]u16 = undefined;
    const n = win.GetModuleFileNameW(null, &wbuf, wbuf.len - 1);
    if (n == 0 or n >= wbuf.len) return;
    var u8buf: [1024]u8 = undefined;
    const exe = eu5_files.utf16ToUtf8(wbuf[0..n], &u8buf) orelse return;
    var old_buf: [1040]u8 = undefined;
    const old_path = root.bufPrintZ(&old_buf, "{s}.old", .{exe}) catch return;
    if (eu5_files.fileExists(old_path.ptr)) {
        eu5_files.deleteFileUtf8(old_path.ptr);
    }
}

/// Removes legacy Ruby directories (`lib/`, `bin/`) under a Linux install folder while keeping `config.toml` and `logs/`.
pub fn cleanupLegacyRubyLinux(app_dir: []const u8) void {
    if (builtin.os.tag == .windows) return;
    var sub_buf: [640]u8 = undefined;
    if (root.bufPrintZ(&sub_buf, "{s}/lib", .{app_dir})) |p| removeDirRecursivePosix(p) else |_| {}
    if (root.bufPrintZ(&sub_buf, "{s}/bin", .{app_dir})) |p| removeDirRecursivePosix(p) else |_| {}
}

fn removeDirRecursivePosix(dir_z: [:0]const u8) void {
    if (builtin.os.tag == .windows) return;
    const d = posix.opendir(dir_z.ptr) orelse return;
    while (posix.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var child_buf: [768]u8 = undefined;
        const child = root.bufPrintZ(&child_buf, "{s}/{s}", .{ dir_z, name }) catch continue;
        if (eu5_files.dirExists(child.ptr)) {
            removeDirRecursivePosix(child);
        } else {
            _ = posix.unlink(child.ptr);
        }
    }
    _ = posix.closedir(d);
    _ = posix.rmdir(dir_z.ptr);
}

fn httpGetAlloc(alloc: std.mem.Allocator, io: std.Io, url: []const u8, max_bytes: usize) ![]u8 {
    var client = std.http.Client{
        .allocator = alloc,
        .io = io,
    };
    defer client.deinit();

    var body = std.Io.Writer.Allocating.init(alloc);
    errdefer body.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "eu5-rpc/" ++ root.VERSION },
            .{ .name = "Accept", .value = "application/vnd.github+json" },
        },
    });
    if (res.status != .ok) return error.HttpError;
    if (body.written().len == 0 or body.written().len > max_bytes) return error.InvalidResponseSize;
    return try body.toOwnedSlice();
}

/// Checks GitHub's latest release and detects whether an update or Ruby-to-Zig migration is needed.
pub fn checkForUpdate(alloc: std.mem.Allocator, io: std.Io) CheckResult {
    const legacy_ruby = detectLegacyRubyInstall();
    const raw_json = httpGetAlloc(alloc, io, GITHUB_LATEST_API_URL, 512 * 1024) catch {
        return .{ .status = .check_failed, .legacy_ruby_detected = legacy_ruby };
    };
    defer alloc.free(raw_json);

    const rel = parseLatestReleaseJson(raw_json) orelse {
        return .{ .status = .check_failed, .legacy_ruby_detected = legacy_ruby };
    };
    if (rel.is_draft or rel.is_prerelease) {
        return .{ .status = .up_to_date, .release = rel, .legacy_ruby_detected = legacy_ruby };
    }

    const current = SemVer.parse(root.VERSION) orelse SemVer{};
    if (legacy_ruby) {
        return .{
            .status = .migrating_from_ruby,
            .release = rel,
            .legacy_ruby_detected = true,
        };
    }
    if (rel.version.isNewerThan(current)) {
        return .{
            .status = .update_available,
            .release = rel,
            .legacy_ruby_detected = false,
        };
    }
    return .{
        .status = .up_to_date,
        .release = rel,
        .legacy_ruby_detected = false,
    };
}

fn parseOctal(field: []const u8) usize {
    var val: usize = 0;
    for (field) |ch| {
        if (ch == 0 or ch == ' ') {
            if (val > 0) break;
            continue;
        }
        if (ch < '0' or ch > '7') break;
        val = (val << 3) | (ch - '0');
    }
    return val;
}

/// Extracts `eu5-rpc-linux-x86_64/eu5-rpc` (or any entry ending in `/eu5-rpc`) from a gzipped USTAR tarball in pure Zig.
pub fn extractLinuxBinaryFromTarGz(alloc: std.mem.Allocator, gz_bytes: []const u8) ![]u8 {
    var in_reader = std.Io.Reader.fixed(gz_bytes);
    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);

    var dec = std.compress.flate.Decompress.init(&in_reader, .gzip, window);
    var tar_out = std.Io.Writer.Allocating.init(alloc);
    defer tar_out.deinit();

    _ = try dec.reader.streamRemaining(&tar_out.writer);
    const tar = tar_out.written();

    var off: usize = 0;
    while (off + 512 <= tar.len) {
        const hdr = tar[off .. off + 512];
        // Zero block marks end of archive
        var all_zero = true;
        for (hdr) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) break;

        const name_end = std.mem.indexOfScalar(u8, hdr[0..100], 0) orelse 100;
        const name = hdr[0..name_end];
        const size = parseOctal(hdr[124..136]);
        const data_start = off + 512;
        if (data_start + size > tar.len) return error.TruncatedArchive;

        if (std.mem.endsWith(u8, name, "/eu5-rpc") or std.mem.eql(u8, name, "eu5-rpc")) {
            const payload = tar[data_start .. data_start + size];
            if (payload.len < 4 or !std.mem.eql(u8, payload[0..4], "\x7fELF")) {
                return error.InvalidBinary;
            }
            return try alloc.dupe(u8, payload);
        }

        const padded = ((size + 511) / 512) * 512;
        off = data_start + padded;
    }
    return error.BinaryNotFound;
}

/// Downloads and applies the release update for the current OS.
/// Returns `true` if the update succeeded and the newly installed version was launched (caller should exit).
pub fn applyUpdate(alloc: std.mem.Allocator, io: std.Io, release: *const ReleaseInfo) bool {
    if (builtin.os.tag == .windows) {
        const url = release.winAssetUrl() orelse return false;
        const installer_bytes = httpGetAlloc(alloc, io, url, 32 * 1024 * 1024) catch return false;
        defer alloc.free(installer_bytes);

        // Sanity check PE header ("MZ")
        if (installer_bytes.len < 64 or installer_bytes[0] != 'M' or installer_bytes[1] != 'Z') return false;

        var temp_buf: [512]u8 = undefined;
        const temp_dir = eu5_files.getEnvUtf8("TEMP", &temp_buf) orelse return false;
        var setup_buf: [640]u8 = undefined;
        const setup_path = root.bufPrintZ(&setup_buf, "{s}\\EU5-RPC-Setup-Update.exe", .{temp_dir}) catch return false;
        if (!eu5_files.writeFileAll(setup_path.ptr, installer_bytes)) return false;

        // Rename currently running exe to .old so the silent installer can write the fresh eu5-rpc.exe cleanly
        var self_w: [1024]u16 = undefined;
        const self_n = win.GetModuleFileNameW(null, &self_w, self_w.len - 1);
        if (self_n > 0 and self_n < self_w.len) {
            self_w[self_n] = 0;
            var self_u8_buf: [1024]u8 = undefined;
            if (eu5_files.utf16ToUtf8(self_w[0..self_n], &self_u8_buf)) |self_u8| {
                var old_u8_buf: [1040]u8 = undefined;
                if (root.bufPrintZ(&old_u8_buf, "{s}.old", .{self_u8})) |old_u8| {
                    var old_w: [1040]u16 = undefined;
                    if (eu5_files.utf8ToUtf16Z(old_u8, &old_w)) |ow| {
                        _ = win.MoveFileExW(@ptrCast(&self_w), ow.ptr, win.MOVEFILE_REPLACE_EXISTING);
                    }
                } else |_| {}
            }
        }

        // Run silent Zig installer (writes new eu5-rpc.exe, cleans legacy Ruby files & registry, preserves config.toml)
        var cmd_buf: [700]u8 = undefined;
        const cmd = root.bufPrintZ(&cmd_buf, "\"{s}\" --silent", .{setup_path}) catch return false;
        var cmd_w: [768]u16 = undefined;
        const cw = eu5_files.utf8ToUtf16Z(cmd, &cmd_w) orelse return false;
        var si = std.mem.zeroes(win.STARTUPINFOW);
        si.cb = @sizeOf(win.STARTUPINFOW);
        var pi = std.mem.zeroes(win.PROCESS_INFORMATION);
        if (win.CreateProcessW(null, @constCast(cw.ptr), null, null, 0, 0, null, null, &si, &pi) == 0) return false;
        _ = win.WaitForSingleObject(pi.hProcess, win.INFINITE);
        _ = win.CloseHandle(pi.hProcess);
        _ = win.CloseHandle(pi.hThread);
        eu5_files.deleteFileUtf8(setup_path.ptr);

        // Relaunch the newly installed Zig eu5-rpc.exe (without re-launching EU5 if already running)
        var la_buf: [512]u8 = undefined;
        if (eu5_files.getEnvUtf8("LOCALAPPDATA", &la_buf)) |la| {
            var new_cmd_buf: [700]u8 = undefined;
            if (root.bufPrintZ(&new_cmd_buf, "\"{s}\\EU5-RPC\\eu5-rpc.exe\" --no-launch --no-update", .{la})) |nc| {
                var nc_w: [768]u16 = undefined;
                if (eu5_files.utf8ToUtf16Z(nc, &nc_w)) |ncw| {
                    var si2 = std.mem.zeroes(win.STARTUPINFOW);
                    si2.cb = @sizeOf(win.STARTUPINFOW);
                    var pi2 = std.mem.zeroes(win.PROCESS_INFORMATION);
                    if (win.CreateProcessW(null, @constCast(ncw.ptr), null, null, 0, 0, null, null, &si2, &pi2) != 0) {
                        _ = win.CloseHandle(pi2.hProcess);
                        _ = win.CloseHandle(pi2.hThread);
                    }
                }
            } else |_| {}
        }
        return true;
    } else {
        const url = release.linuxAssetUrl() orelse return false;
        const gz_bytes = httpGetAlloc(alloc, io, url, 32 * 1024 * 1024) catch return false;
        defer alloc.free(gz_bytes);

        const elf_bytes = extractLinuxBinaryFromTarGz(alloc, gz_bytes) catch return false;
        defer alloc.free(elf_bytes);

        var self_buf: [512]u8 = undefined;
        const self_len = posix.readlink("/proc/self/exe", &self_buf, self_buf.len - 1);
        if (self_len <= 0) return false;
        const self_path = self_buf[0..@intCast(self_len)];
        self_buf[@intCast(self_len)] = 0;

        var tmp_buf: [560]u8 = undefined;
        const tmp_path = root.bufPrintZ(&tmp_buf, "{s}.new", .{self_path}) catch return false;
        if (!eu5_files.writeFileAll(tmp_path.ptr, elf_bytes)) return false;
        _ = posix.chmod(tmp_path.ptr, 0o755);

        if (posix.rename(tmp_path.ptr, @ptrCast(&self_buf)) != 0) {
            _ = posix.unlink(tmp_path.ptr);
            return false;
        }

        // Clean up any legacy Ruby installation in ~/.local/share/eu5-rpc and ensure symlink points to Zig binary
        var env_buf: [512]u8 = undefined;
        if (eu5_files.getEnvUtf8("HOME", &env_buf)) |home| {
            const h = std.mem.trimEnd(u8, home, "/");
            var app_buf: [600]u8 = undefined;
            if (root.bufPrintZ(&app_buf, "{s}/.local/share/eu5-rpc", .{h})) |app_dir| {
                cleanupLegacyRubyLinux(app_dir);
                var link_buf: [600]u8 = undefined;
                if (root.bufPrintZ(&link_buf, "{s}/.local/bin/eu5-rpc", .{h})) |link_path| {
                    _ = posix.unlink(link_path.ptr);
                    _ = posix.symlink(@ptrCast(&self_buf), link_path.ptr);
                } else |_| {}
            } else |_| {}
        }

        // Spawn refreshed binary cleanly
        const pid = posix.fork();
        if (pid == 0) {
            const pid2 = posix.fork();
            if (pid2 == 0) {
                const argv = [_:null]?[*:0]const u8{
                    @ptrCast(&self_buf),
                    "--no-launch",
                    "--no-update",
                };
                _ = posix.execv(@ptrCast(&self_buf), &argv);
                posix._exit(1);
            }
            posix._exit(0);
        } else if (pid > 0) {
            var st: c_int = 0;
            _ = posix.waitpid(pid, &st, 0);
        }
        return true;
    }
}

test "SemVer parsing and comparison handles v-prefixes, 2-part versions, and Ruby-to-Zig upgrades" {
    const v033 = SemVer.parse("v0.3.3").?;
    const v400 = SemVer.parse("v4.0.0").?;
    const v410 = SemVer.parse("v4.1").?;
    const v411 = SemVer.parse("4.1.1-beta").?;

    try std.testing.expect(v400.isNewerThan(v033));
    try std.testing.expect(v410.isNewerThan(v400));
    try std.testing.expect(v411.isNewerThan(v410));
    try std.testing.expect(!v410.isNewerThan(v410));
    try std.testing.expect(!v400.isNewerThan(v410));
}

test "parseLatestReleaseJson extracts tag, URLs, and rejects untrusted asset hosts" {
    const sample =
        \\{
        \\  "tag_name": "v4.2.0",
        \\  "draft": false,
        \\  "prerelease": false,
        \\  "html_url": "https://github.com/buntatoes/eu5-rpc/releases/tag/v4.2.0",
        \\  "assets": [
        \\    {
        \\      "name": "evil.exe",
        \\      "browser_download_url": "https://evil.example.com/evil.exe"
        \\    },
        \\    {
        \\      "name": "EU5-RPC-Setup-v4.2.0-win64.exe",
        \\      "browser_download_url": "https://github.com/buntatoes/eu5-rpc/releases/download/v4.2.0/EU5-RPC-Setup-v4.2.0-win64.exe"
        \\    },
        \\    {
        \\      "name": "eu5-rpc-linux-x86_64.tar.gz",
        \\      "browser_download_url": "https://github.com/buntatoes/eu5-rpc/releases/download/v4.2.0/eu5-rpc-linux-x86_64.tar.gz"
        \\    }
        \\  ]
        \\}
    ;

    const rel = parseLatestReleaseJson(sample).?;
    try std.testing.expectEqualStrings("v4.2.0", rel.tagName());
    try std.testing.expectEqual(@as(u32, 4), rel.version.major);
    try std.testing.expectEqual(@as(u32, 2), rel.version.minor);
    try std.testing.expectEqualStrings(
        "https://github.com/buntatoes/eu5-rpc/releases/download/v4.2.0/EU5-RPC-Setup-v4.2.0-win64.exe",
        rel.winAssetUrl().?,
    );
    try std.testing.expectEqualStrings(
        "https://github.com/buntatoes/eu5-rpc/releases/download/v4.2.0/eu5-rpc-linux-x86_64.tar.gz",
        rel.linuxAssetUrl().?,
    );
}

test "extractLinuxBinaryFromTarGz extracts valid ELF payload in pure Zig" {
    const fake_elf = "\x7fELF\x02\x01\x01\x00EU5RPC_TEST_PAYLOAD";

    var tar_buf = std.ArrayList(u8).empty;
    defer tar_buf.deinit(std.testing.allocator);

    var hdr: [512]u8 = std.mem.zeroes([512]u8);
    const entry_name = "eu5-rpc-linux-x86_64/eu5-rpc";
    @memcpy(hdr[0..entry_name.len], entry_name);
    _ = std.fmt.bufPrint(hdr[124..135], "{o:0>11}", .{fake_elf.len}) catch unreachable;
    hdr[156] = '0';
    try tar_buf.appendSlice(std.testing.allocator, &hdr);
    try tar_buf.appendSlice(std.testing.allocator, fake_elf);
    const pad_len = 512 - (fake_elf.len % 512);
    var pad: [512]u8 = std.mem.zeroes([512]u8);
    try tar_buf.appendSlice(std.testing.allocator, pad[0..pad_len]);
    var zeros: [1024]u8 = std.mem.zeroes([1024]u8);
    try tar_buf.appendSlice(std.testing.allocator, &zeros);

    var gz_out: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&gz_out);
    const window = try std.testing.allocator.alloc(u8, std.compress.flate.max_window_len);
    defer std.testing.allocator.free(window);

    var comp = try std.compress.flate.Compress.init(&writer, window, .gzip, .default);
    try comp.writer.writeAll(tar_buf.items);
    try comp.finish();

    const extracted = try extractLinuxBinaryFromTarGz(std.testing.allocator, writer.buffered());
    defer std.testing.allocator.free(extracted);
    try std.testing.expectEqualStrings(fake_elf, extracted);
}
