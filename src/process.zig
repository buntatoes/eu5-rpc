// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");

const win = if (builtin.os.tag == .windows) struct {
    const HANDLE = ?*anyopaque;
    const HWND = ?*anyopaque;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const TH32CS_SNAPPROCESS: u32 = 0x00000002;
    const WM_CLOSE: u32 = 0x0010;
    const PROCESS_TERMINATE: u32 = 0x0001;

    const PROCESSENTRY32 = extern struct {
        dwSize: u32,
        cntUsage: u32,
        th32ProcessID: u32,
        th32DefaultHeapID: usize,
        th32ModuleID: u32,
        cntThreads: u32,
        th32ParentProcessID: u32,
        pcPriClassBase: i32,
        dwFlags: u32,
        szExeFile: [260]u8,
    };

    const EnumWindowsProc = *const fn (HWND, isize) callconv(.winapi) i32;

    extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: u32, th32ProcessID: u32) callconv(.winapi) HANDLE;
    extern "kernel32" fn Process32First(hSnapshot: HANDLE, lppe: *PROCESSENTRY32) callconv(.winapi) i32;
    extern "kernel32" fn Process32Next(hSnapshot: HANDLE, lppe: *PROCESSENTRY32) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
    extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: i32, dwProcessId: u32) callconv(.winapi) HANDLE;
    extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.winapi) i32;
    extern "user32" fn EnumWindows(lpEnumFunc: EnumWindowsProc, lParam: isize) callconv(.winapi) i32;
    extern "user32" fn GetWindowThreadProcessId(hWnd: HWND, lpdwProcessId: *u32) callconv(.winapi) u32;
    extern "user32" fn PostMessageW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) i32;
} else struct {};

const posix = if (builtin.os.tag != .windows) struct {
    const DIR = anyopaque;
    const FILE = anyopaque;
    const SIGTERM: c_int = 15;
    const SIGKILL: c_int = 9;
    const Dirent = extern struct {
        d_ino: u64,
        d_off: i64,
        d_reclen: u16,
        d_type: u8,
        d_name: [256]u8,
    };
    extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
    extern "c" fn readdir(dirp: *DIR) ?*Dirent;
    extern "c" fn closedir(dirp: *DIR) c_int;
    extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
    extern "c" fn fclose(stream: *FILE) c_int;
    extern "c" fn getpid() c_int;
    extern "c" fn kill(pid: c_int, sig: c_int) c_int;
    extern "c" fn usleep(usec: u32) c_int;
} else struct {};

/// Native zero-subprocess, 100% VAC-safe & read-only process watcher.
/// Windows: CreateToolhelp32Snapshot (never calls ReadProcessMemory or injects code).
/// Linux:   /proc/<pid>/comm and /proc/<pid>/cmdline scan (never opens /proc/<pid>/mem or calls ptrace).
/// Supports native Linux, Steam Proton, Wine, GE-Proton, Steam Linux Runtime, Gamescope, GameMode, MangoHud, umu, and NixOS steam-run.
fn basenameAny(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') {
            start = i + 1;
        }
    }
    return path[start..];
}

fn trimArg(arg: []const u8) []const u8 {
    return std.mem.trim(u8, arg, " \t\r\n\"'");
}

fn isBoundaryBefore(ch: u8) bool {
    return ch == '/' or ch == '\\' or ch == '"' or ch == '\'';
}

fn isBoundaryAfter(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '"' or ch == '\'';
}

/// Checks whether a single argv element refers to `target_exe` (e.g. `eu5.exe`) or `target_no_exe` (`eu5`),
/// including Wine/Proton command lines where argv[0] contains a Windows path plus flags
/// (e.g. `Z:\path with spaces\Europa Universalis V\binaries\eu5.exe -gdpr`).
pub fn argMatchesTarget(raw_arg: []const u8, target_exe: []const u8, target_no_exe: []const u8, allow_no_exe: bool) bool {
    const arg = trimArg(raw_arg);
    if (arg.len == 0) return false;

    const base = basenameAny(arg);
    if (std.ascii.eqlIgnoreCase(base, target_exe)) return true;
    if (allow_no_exe and std.ascii.eqlIgnoreCase(base, target_no_exe)) return true;

    // Handle Wine/Proton single-string argv with trailing flags after `.exe`
    if (target_exe.len > 0 and arg.len > target_exe.len) {
        var i: usize = 0;
        while (i + target_exe.len <= arg.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(arg[i .. i + target_exe.len], target_exe)) {
                const ok_before = (i == 0) or isBoundaryBefore(arg[i - 1]);
                const end = i + target_exe.len;
                const ok_after = (end == arg.len) or isBoundaryAfter(arg[end]);
                if (ok_before and ok_after) {
                    return true;
                }
            }
        }
    }
    return false;
}

fn isWineWrapper(base: []const u8) bool {
    const wrappers = [_][]const u8{
        "wine",
        "wine64",
        "wine-preloader",
        "wine64-preloader",
        "proton",
        "umu-run",
    };
    for (wrappers) |w| {
        if (std.ascii.eqlIgnoreCase(base, w)) return true;
    }
    return false;
}

fn isLinuxRuntimeWrapper(base: []const u8) bool {
    const wrappers = [_][]const u8{
        "reaper",
        "pressure-vessel-adverb",
        "srt-bwrap",
        "bwrap",
        "gamemoderun",
        "gamescope",
        "mangohud",
        "steam-run",
        "prime-run",
    };
    for (wrappers) |w| {
        if (std.ascii.eqlIgnoreCase(base, w)) return true;
    }
    return false;
}

fn isPythonExe(base: []const u8) bool {
    return std.ascii.eqlIgnoreCase(base, "python") or
        std.ascii.eqlIgnoreCase(base, "python3") or
        std.ascii.startsWithIgnoreCase(base, "python3.");
}

/// Checks a NUL-delimited Linux `/proc/<pid>/cmdline` buffer against `target_exe` (e.g. `eu5.exe`).
/// User-, distro-, DE-, drive-, and mount-agnostic; avoids false positives from launchers, shells, or `eu5-rpc`.
pub fn cmdlineMatchesTarget(cmdline: []const u8, target_exe: []const u8) bool {
    if (cmdline.len == 0) return false;

    const target_no_exe = if (std.mem.endsWith(u8, target_exe, ".exe"))
        target_exe[0 .. target_exe.len - 4]
    else
        target_exe;

    var it = std.mem.splitScalar(u8, cmdline, 0);
    var cmd = it.next() orelse return false;
    if (cmd.len == 0) return false;

    // Unwrap leading `env [FLAGS] [VAR=VAL ...] <real_cmd> ...` safely without false-matching `env FOO=1 echo eu5.exe`
    if (std.ascii.eqlIgnoreCase(basenameAny(trimArg(cmd)), "env")) {
        var next_cmd: ?[]const u8 = null;
        while (it.next()) |arg| {
            if (arg.len == 0) continue;
            if (arg[0] == '-') continue;
            if (std.mem.indexOfScalar(u8, arg, '=') != null and arg[0] != '/' and arg[0] != '.') continue;
            next_cmd = arg;
            break;
        }
        cmd = next_cmd orelse return false;
    }

    if (argMatchesTarget(cmd, target_exe, target_no_exe, true)) {
        return true;
    }

    const base = basenameAny(trimArg(cmd));

    if (isWineWrapper(base)) {
        while (it.next()) |arg| {
            if (arg.len == 0 or arg[0] == '-') continue;
            if (argMatchesTarget(arg, target_exe, target_no_exe, false)) {
                return true;
            }
        }
        return false;
    }

    if (isLinuxRuntimeWrapper(base)) {
        while (it.next()) |arg| {
            if (arg.len == 0 or arg[0] == '-') continue;
            if (argMatchesTarget(arg, target_exe, target_no_exe, true)) {
                return true;
            }
        }
        return false;
    }

    if (isPythonExe(base)) {
        var saw_proton = false;
        while (it.next()) |arg| {
            if (arg.len == 0 or arg[0] == '-') continue;
            const abase = basenameAny(trimArg(arg));
            if (std.ascii.eqlIgnoreCase(abase, "proton") or
                std.ascii.eqlIgnoreCase(abase, "proton.py") or
                std.ascii.eqlIgnoreCase(abase, "umu-run"))
            {
                saw_proton = true;
                continue;
            }
            if (saw_proton and argMatchesTarget(arg, target_exe, target_no_exe, false)) {
                return true;
            }
        }
    }

    return false;
}

pub fn collectMatchingPids(target_exe: []const u8, out_pids: []u32) usize {
    var count: usize = 0;
    if (builtin.os.tag == .windows) {
        const snap = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);
        if (snap == win.INVALID_HANDLE_VALUE) return 0;
        defer _ = win.CloseHandle(snap);

        var entry = std.mem.zeroes(win.PROCESSENTRY32);
        entry.dwSize = @sizeOf(win.PROCESSENTRY32);

        if (win.Process32First(snap, &entry) == 0) return 0;
        while (true) {
            const name_ptr: [*:0]const u8 = @ptrCast(&entry.szExeFile);
            const name = std.mem.span(name_ptr);
            if (std.ascii.eqlIgnoreCase(name, target_exe)) {
                if (count < out_pids.len) {
                    out_pids[count] = entry.th32ProcessID;
                    count += 1;
                }
            }
            if (win.Process32Next(snap, &entry) == 0) break;
        }
        return count;
    } else {
        const dir = posix.opendir("/proc") orelse return 0;
        defer _ = posix.closedir(dir);

        const self_pid: u32 = @intCast(posix.getpid());
        const target_no_exe = if (std.mem.endsWith(u8, target_exe, ".exe"))
            target_exe[0 .. target_exe.len - 4]
        else
            target_exe;

        while (posix.readdir(dir)) |ent| {
            const dname_ptr: [*:0]const u8 = @ptrCast(&ent.d_name);
            const dname = std.mem.span(dname_ptr);
            if (dname.len == 0 or dname[0] < '0' or dname[0] > '9') continue;
            const pid = std.fmt.parseInt(u32, dname, 10) catch continue;
            if (pid == self_pid) continue;

            var matched = false;
            var path_buf: [128]u8 = undefined;
            if (root.bufPrintZ(&path_buf, "/proc/{s}/comm", .{dname})) |comm_path| {
                if (posix.fopen(comm_path.ptr, "rb")) |fp| {
                    defer _ = posix.fclose(fp);
                    var line_buf: [128]u8 = undefined;
                    const n = posix.fread(&line_buf, 1, line_buf.len, fp);
                    if (n > 0) {
                        const comm = std.mem.trim(u8, line_buf[0..n], " \t\r\n");
                        if (std.ascii.eqlIgnoreCase(comm, target_exe) or std.ascii.eqlIgnoreCase(comm, target_no_exe)) {
                            matched = true;
                        }
                    }
                }
            } else |_| {}

            if (!matched) {
                if (root.bufPrintZ(&path_buf, "/proc/{s}/cmdline", .{dname})) |cmd_path| {
                    if (posix.fopen(cmd_path.ptr, "rb")) |fp| {
                        defer _ = posix.fclose(fp);
                        var cmd_buf: [4096]u8 = undefined;
                        const n = posix.fread(&cmd_buf, 1, cmd_buf.len, fp);
                        if (n > 0 and cmdlineMatchesTarget(cmd_buf[0..n], target_exe)) {
                            matched = true;
                        }
                    }
                } else |_| {}
            }

            if (matched and count < out_pids.len) {
                out_pids[count] = pid;
                count += 1;
            }
        }
        return count;
    }
}

pub fn processRunning(target_exe: []const u8) bool {
    var pids: [1]u32 = undefined;
    return collectMatchingPids(target_exe, &pids) > 0;
}

pub fn eu5Running() bool {
    return processRunning("eu5.exe");
}

const WinCloseCtx = struct {
    pids: []const u32,
};

fn enumCloseWindowCb(hwnd: if (builtin.os.tag == .windows) win.HWND else ?*anyopaque, lparam: isize) callconv(.winapi) i32 {
    if (builtin.os.tag != .windows) return 1;
    const ctx: *const WinCloseCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    var wpid: u32 = 0;
    _ = win.GetWindowThreadProcessId(hwnd, &wpid);
    for (ctx.pids) |p| {
        if (p == wpid) {
            _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
            break;
        }
    }
    return 1;
}

/// Gracefully closes Europa Universalis V when the user explicitly selects Quit from the tray menu.
/// Windows: posts standard WM_CLOSE to game windows first, falling back to minimal PROCESS_TERMINATE if unresponsive.
/// Linux:   sends SIGTERM first to matching EU5/Proton PIDs, falling back to SIGKILL after 3 seconds if still running.
pub fn closeEu5() void {
    var pids: [32]u32 = undefined;
    const n = collectMatchingPids("eu5.exe", &pids);
    if (n == 0) return;

    if (builtin.os.tag == .windows) {
        var ctx = WinCloseCtx{ .pids = pids[0..n] };
        _ = win.EnumWindows(enumCloseWindowCb, @as(isize, @bitCast(@intFromPtr(&ctx))));

        var waited_ms: u32 = 0;
        while (waited_ms < 3000) : (waited_ms += 100) {
            if (!eu5Running()) return;
            win.Sleep(100);
        }

        const rem = collectMatchingPids("eu5.exe", &pids);
        for (pids[0..rem]) |pid| {
            const h = win.OpenProcess(win.PROCESS_TERMINATE, 0, pid);
            if (h != null) {
                _ = win.TerminateProcess(h, 0);
                _ = win.CloseHandle(h);
            }
        }
    } else {
        for (pids[0..n]) |pid| {
            _ = posix.kill(@intCast(pid), posix.SIGTERM);
        }

        var waited_ms: u32 = 0;
        while (waited_ms < 3000) : (waited_ms += 100) {
            if (!eu5Running()) return;
            _ = posix.usleep(100 * 1000);
        }

        const rem = collectMatchingPids("eu5.exe", &pids);
        for (pids[0..rem]) |pid| {
            _ = posix.kill(@intCast(pid), posix.SIGKILL);
        }
    }
}

test "native process enumeration reports non-existent process as false" {
    try std.testing.expectEqual(false, processRunning("definitely_not_running_eu5_99999.exe"));
}

test "cmdline matching detects native Linux, Proton, Wine, Gamescope, GameMode, and Flatpak/NixOS wrappers" {
    try std.testing.expect(cmdlineMatchesTarget(
        "Z:\\mnt\\games\\SteamLibrary\\steamapps\\common\\Europa Universalis V\\binaries\\eu5.exe\x00",
        "eu5.exe",
    ));
    try std.testing.expect(cmdlineMatchesTarget(
        "Z:\\path\\to\\binaries\\eu5.exe -gdpr\x00",
        "eu5.exe",
    ));
    try std.testing.expect(cmdlineMatchesTarget(
        "/opt/proton/bin/wine64-preloader\x00Z:\\path\\to\\eu5.exe\x00",
        "eu5.exe",
    ));
    try std.testing.expect(cmdlineMatchesTarget(
        "/usr/bin/reaper\x00SteamLaunch\x00AppId=3450310\x00--\x00/opt/proton\x00waitforexitandrun\x00/mnt/games/binaries/eu5.exe\x00",
        "eu5.exe",
    ));
    try std.testing.expect(cmdlineMatchesTarget(
        "/usr/bin/python3\x00/opt/proton\x00waitforexitandrun\x00/mnt/games/binaries/eu5.exe\x00",
        "eu5.exe",
    ));
    try std.testing.expect(cmdlineMatchesTarget(
        "/usr/bin/gamemoderun\x00/usr/bin/mangohud\x00/mnt/games/binaries/eu5.exe\x00",
        "eu5.exe",
    ));
    try std.testing.expect(cmdlineMatchesTarget(
        "/usr/bin/gamescope\x00-W\x002560\x00-H\x001440\x00--\x00/mnt/games/binaries/eu5.exe\x00",
        "eu5.exe",
    ));
    try std.testing.expect(cmdlineMatchesTarget(
        "/usr/bin/env\x00PROTON_ENABLE_NVAPI=1\x00/opt/proton\x00waitforexitandrun\x00/mnt/games/binaries/eu5.exe\x00",
        "eu5.exe",
    ));
    try std.testing.expect(cmdlineMatchesTarget(
        "/mnt/games/binaries/eu5\x00",
        "eu5.exe",
    ));
}

test "cmdline matching avoids false positives on eu5-rpc, steam, shells, env echo, and unrelated python" {
    try std.testing.expect(!cmdlineMatchesTarget("/usr/local/bin/eu5-rpc\x00--no-launch\x00", "eu5.exe"));
    try std.testing.expect(!cmdlineMatchesTarget("/usr/bin/steam\x00-applaunch\x003450310\x00", "eu5.exe"));
    try std.testing.expect(!cmdlineMatchesTarget("bash\x00-c\x00echo eu5.exe\x00", "eu5.exe"));
    try std.testing.expect(!cmdlineMatchesTarget("/usr/bin/env\x00FOO=1\x00echo\x00eu5.exe\x00", "eu5.exe"));
    try std.testing.expect(!cmdlineMatchesTarget("python3\x00script.py\x00--target=eu5.exe\x00", "eu5.exe"));
    try std.testing.expect(!cmdlineMatchesTarget("/opt/tools/my_eu5.exe\x00", "eu5.exe"));
}
