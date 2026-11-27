// SPDX-License-Identifier: GPL-3.0-only
// Persistent, zero-hard-dependency System Tray icon for EU5 RPC:
// - Windows: Native Win32 Shell_NotifyIconW + TaskbarCreated auto-recovery + popup menu + balloon notifications.
// - Linux:   StatusNotifierItem (org.kde.StatusNotifierItem + com.canonical.dbusmenu + org.freedesktop.Notifications)
//            over dynamically loaded libdbus-1.so.3 (works natively on KDE Plasma, GNOME AppIndicator, XFCE,
//            Cinnamon, MATE, Waybar, Hyprpanel, Swaybar across Wayland & X11; gracefully no-ops if headless).
// - Selecting "Quit (Close EU5 & RPC)" closes Europa Universalis V and exits EU5 RPC cleanly.
const std = @import("std");
const builtin = @import("builtin");
const eu5_files = @import("eu5_files.zig");
const root = @import("root.zig");

const ICON_PNG = @embedFile("icon_png");

pub const TrayAction = enum {
    none,
    launch_game,
    check_update,
    open_config,
    quit_all,
};

const SpinLock = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinLock) void {
        while (self.flag.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

pub const Tray = struct {
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    quit_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    launch_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    check_update_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    open_config_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    game_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    status_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    notify_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    mu: SpinLock = .{},
    status_buf: [192]u8 = undefined,
    status_len: usize = 0,
    notify_title_buf: [64]u8 = undefined,
    notify_title_len: usize = 0,
    notify_body_buf: [256]u8 = undefined,
    notify_body_len: usize = 0,

    thread: ?std.Thread = null,
    win_hwnd: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init() Tray {
        var t = Tray{};
        t.setStatusInternal("Waiting for Europa Universalis V");
        return t;
    }

    pub fn start(self: *Tray) void {
        if (self.thread != null) return;
        self.stop_flag.store(false, .release);
        self.thread = std.Thread.spawn(.{}, trayThreadMain, .{self}) catch null;
    }

    pub fn stopAndJoin(self: *Tray) void {
        self.stop_flag.store(true, .release);
        if (builtin.os.tag == .windows) {
            const raw_hwnd = self.win_hwnd.load(.acquire);
            if (raw_hwnd != 0) {
                _ = win.PostMessageW(@ptrFromInt(raw_hwnd), win.WM_APP_STOP, 0, 0);
            }
        }
        if (self.thread) |th| {
            th.join();
            self.thread = null;
        }
    }

    pub fn updateStatus(self: *Tray, status_text: []const u8, is_game_running: bool) void {
        self.game_running.store(is_game_running, .release);
        self.mu.lock();
        const same = (status_text.len == self.status_len) and
            std.mem.eql(u8, self.status_buf[0..self.status_len], status_text);
        if (!same) {
            const n = @min(status_text.len, self.status_buf.len);
            @memcpy(self.status_buf[0..n], status_text[0..n]);
            self.status_len = n;
        }
        self.mu.unlock();

        if (!same) {
            self.status_dirty.store(true, .release);
            if (builtin.os.tag == .windows) {
                const raw_hwnd = self.win_hwnd.load(.acquire);
                if (raw_hwnd != 0) {
                    _ = win.PostMessageW(@ptrFromInt(raw_hwnd), win.WM_APP_UPDATE, 0, 0);
                }
            }
        }
    }

    pub fn notify(self: *Tray, title: []const u8, body: []const u8) void {
        self.mu.lock();
        const tn = @min(title.len, self.notify_title_buf.len);
        @memcpy(self.notify_title_buf[0..tn], title[0..tn]);
        self.notify_title_len = tn;
        const bn = @min(body.len, self.notify_body_buf.len);
        @memcpy(self.notify_body_buf[0..bn], body[0..bn]);
        self.notify_body_len = bn;
        self.mu.unlock();

        self.notify_pending.store(true, .release);
        if (builtin.os.tag == .windows) {
            const raw_hwnd = self.win_hwnd.load(.acquire);
            if (raw_hwnd != 0) {
                _ = win.PostMessageW(@ptrFromInt(raw_hwnd), win.WM_APP_NOTIFY, 0, 0);
            }
        }
    }

    pub fn pollAction(self: *Tray) TrayAction {
        if (self.quit_requested.swap(false, .acq_rel)) return .quit_all;
        if (self.launch_requested.swap(false, .acq_rel)) return .launch_game;
        if (self.check_update_requested.swap(false, .acq_rel)) return .check_update;
        if (self.open_config_requested.swap(false, .acq_rel)) return .open_config;
        return .none;
    }

    fn setStatusInternal(self: *Tray, text: []const u8) void {
        const n = @min(text.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], text[0..n]);
        self.status_len = n;
    }

    fn copyStatus(self: *Tray, out: []u8) []const u8 {
        self.mu.lock();
        const n = @min(self.status_len, out.len);
        @memcpy(out[0..n], self.status_buf[0..n]);
        self.mu.unlock();
        return out[0..n];
    }

    fn takeNotify(self: *Tray, title_out: []u8, body_out: []u8) ?struct { title: []const u8, body: []const u8 } {
        if (!self.notify_pending.swap(false, .acq_rel)) return null;
        self.mu.lock();
        const tn = @min(self.notify_title_len, title_out.len);
        @memcpy(title_out[0..tn], self.notify_title_buf[0..tn]);
        const bn = @min(self.notify_body_len, body_out.len);
        @memcpy(body_out[0..bn], self.notify_body_buf[0..bn]);
        self.mu.unlock();
        return .{ .title = title_out[0..tn], .body = body_out[0..bn] };
    }
};

fn trayThreadMain(tray: *Tray) void {
    if (builtin.os.tag == .windows) {
        runWindowsTray(tray);
    } else {
        runLinuxTray(tray);
    }
}

/// Opens the configuration directory in the user's native file manager (Explorer / xdg-open).
pub fn openConfigFolder(dir: []const u8) void {
    if (dir.len == 0) return;
    if (builtin.os.tag == .windows) {
        var dir_w: [1024]u16 = undefined;
        const dw = eu5_files.utf8ToUtf16Z(dir, &dir_w) orelse return;
        const open_w = std.unicode.utf8ToUtf16LeStringLiteral("open");
        _ = win.ShellExecuteW(null, open_w.ptr, dw.ptr, null, null, 1);
    } else {
        var dir_z_buf: [640]u8 = undefined;
        const dir_z = root.bufPrintZ(&dir_z_buf, "{s}", .{dir}) catch return;
        const pid = posix.fork();
        if (pid == 0) {
            const pid2 = posix.fork();
            if (pid2 == 0) {
                const argv = [_:null]?[*:0]const u8{ "xdg-open", dir_z.ptr };
                _ = posix.execvp("xdg-open", &argv);
                posix._exit(1);
            }
            posix._exit(0);
        } else if (pid > 0) {
            var st: c_int = 0;
            _ = posix.waitpid(pid, &st, 0);
        }
    }
}

// ============================================================================
// Windows Win32 System Tray (Shell_NotifyIconW)
// ============================================================================

const win = if (builtin.os.tag == .windows) struct {
    const HANDLE = ?*anyopaque;
    const HWND = ?*anyopaque;
    const HINSTANCE = ?*anyopaque;
    const HICON = ?*anyopaque;
    const HMENU = ?*anyopaque;

    const WM_NULL: u32 = 0x0000;
    const WM_DESTROY: u32 = 0x0002;
    const WM_COMMAND: u32 = 0x0111;
    const WM_LBUTTONUP: u32 = 0x0202;
    const WM_RBUTTONUP: u32 = 0x0205;
    const WM_CONTEXTMENU: u32 = 0x007B;
    const WM_APP: u32 = 0x8000;
    const WM_TRAYICON: u32 = WM_APP + 1;
    const WM_APP_UPDATE: u32 = WM_APP + 2;
    const WM_APP_NOTIFY: u32 = WM_APP + 3;
    const WM_APP_STOP: u32 = WM_APP + 4;

    const NIM_ADD: u32 = 0x00000000;
    const NIM_MODIFY: u32 = 0x00000001;
    const NIM_DELETE: u32 = 0x00000002;

    const NIF_MESSAGE: u32 = 0x00000001;
    const NIF_ICON: u32 = 0x00000002;
    const NIF_TIP: u32 = 0x00000004;
    const NIF_INFO: u32 = 0x00000010;
    const NIIF_INFO: u32 = 0x00000001;

    const MF_STRING: u32 = 0x00000000;
    const MF_GRAYED: u32 = 0x00000001;
    const MF_DISABLED: u32 = 0x00000002;
    const MF_SEPARATOR: u32 = 0x00000800;
    const TPM_RIGHTBUTTON: u32 = 0x0002;
    const TPM_BOTTOMALIGN: u32 = 0x0020;

    const IDM_LAUNCH: usize = 1001;
    const IDM_UPDATE: usize = 1002;
    const IDM_CONFIG: usize = 1003;
    const IDM_QUIT: usize = 1004;

    const GUID = extern struct {
        data1: u32,
        data2: u16,
        data3: u16,
        data4: [8]u8,
    };

    const POINT = extern struct {
        x: i32,
        y: i32,
    };

    const MSG = extern struct {
        hwnd: HWND,
        message: u32,
        wParam: usize,
        lParam: isize,
        time: u32,
        pt: POINT,
    };

    const WndProcFn = *const fn (HWND, u32, usize, isize) callconv(.winapi) isize;

    const WNDCLASSEXW = extern struct {
        cbSize: u32,
        style: u32,
        lpfnWndProc: WndProcFn,
        cbClsExtra: i32,
        cbWndExtra: i32,
        hInstance: HINSTANCE,
        hIcon: HICON,
        hCursor: HANDLE,
        hbrBackground: HANDLE,
        lpszMenuName: ?[*:0]const u16,
        lpszClassName: [*:0]const u16,
        hIconSm: HICON,
    };

    const NOTIFYICONDATAW = extern struct {
        cbSize: u32,
        hWnd: HWND,
        uID: u32,
        uFlags: u32,
        uCallbackMessage: u32,
        hIcon: HICON,
        szTip: [128]u16,
        dwState: u32,
        dwStateMask: u32,
        szInfo: [256]u16,
        uTimeoutOrVersion: u32,
        szInfoTitle: [64]u16,
        dwInfoFlags: u32,
        guidItem: GUID,
        hBalloonIcon: HICON,
    };

    extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) HINSTANCE;
    extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) u16;
    extern "user32" fn CreateWindowExW(
        dwExStyle: u32,
        lpClassName: [*:0]const u16,
        lpWindowName: [*:0]const u16,
        dwStyle: u32,
        x: i32,
        y: i32,
        nWidth: i32,
        nHeight: i32,
        hWndParent: HWND,
        hMenu: HMENU,
        hInstance: HINSTANCE,
        lpParam: ?*anyopaque,
    ) callconv(.winapi) HWND;
    extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) i32;
    extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize;
    extern "user32" fn RegisterWindowMessageW(lpString: [*:0]const u16) callconv(.winapi) u32;
    extern "user32" fn LoadIconW(hInstance: HINSTANCE, lpIconName: usize) callconv(.winapi) HICON;
    extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.winapi) i32;
    extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) isize;
    extern "user32" fn PostMessageW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) i32;
    extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
    extern "user32" fn CreatePopupMenu() callconv(.winapi) HMENU;
    extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: u32, uIDNewItem: usize, lpNewItem: ?[*:0]const u16) callconv(.winapi) i32;
    extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: u32, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) i32;
    extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) i32;
    extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) i32;
    extern "shell32" fn Shell_NotifyIconW(dwMessage: u32, lpData: *NOTIFYICONDATAW) callconv(.winapi) i32;
    extern "shell32" fn ShellExecuteW(
        hwnd: HWND,
        lpOperation: ?[*:0]const u16,
        lpFile: [*:0]const u16,
        lpParameters: ?[*:0]const u16,
        lpDirectory: ?[*:0]const u16,
        nShowCmd: i32,
    ) callconv(.winapi) HANDLE;
} else struct {};

var g_win_tray: ?*Tray = null;
var g_win_taskbar_created_msg: u32 = 0;
var g_win_icon: if (builtin.os.tag == .windows) win.HICON else void = if (builtin.os.tag == .windows) null else {};

fn copyUtf8ToWideField(src: []const u8, dst: []u16) void {
    @memset(dst, 0);
    if (dst.len <= 1) return;
    _ = std.unicode.utf8ToUtf16Le(dst[0 .. dst.len - 1], src) catch {
        // Fallback ASCII copy if truncation hits mid-codepoint
        const n = @min(src.len, dst.len - 1);
        for (src[0..n], 0..) |ch, i| {
            dst[i] = if (ch < 0x80) ch else '?';
        }
    };
}

fn winUpdateTrayIcon(hwnd: if (builtin.os.tag == .windows) win.HWND else ?*anyopaque, msg: u32, tray: *Tray) void {
    if (builtin.os.tag != .windows) return;
    var nid = std.mem.zeroes(win.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(win.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = win.NIF_MESSAGE | win.NIF_ICON | win.NIF_TIP;
    nid.uCallbackMessage = win.WM_TRAYICON;
    nid.hIcon = g_win_icon;

    var st_buf: [192]u8 = undefined;
    const st = tray.copyStatus(&st_buf);
    var tip_buf: [192]u8 = undefined;
    const tip = std.fmt.bufPrint(&tip_buf, "EU5 RPC v{s} - {s}", .{ root.VERSION, st }) catch "EU5 RPC";
    copyUtf8ToWideField(tip, &nid.szTip);

    _ = win.Shell_NotifyIconW(msg, &nid);
}

fn winShowNotification(hwnd: if (builtin.os.tag == .windows) win.HWND else ?*anyopaque, tray: *Tray) void {
    if (builtin.os.tag != .windows) return;
    var t_buf: [64]u8 = undefined;
    var b_buf: [256]u8 = undefined;
    const note = tray.takeNotify(&t_buf, &b_buf) orelse return;

    var nid = std.mem.zeroes(win.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(win.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = win.NIF_INFO;
    nid.dwInfoFlags = win.NIIF_INFO;
    copyUtf8ToWideField(note.title, &nid.szInfoTitle);
    copyUtf8ToWideField(note.body, &nid.szInfo);
    _ = win.Shell_NotifyIconW(win.NIM_MODIFY, &nid);
}

fn winShowContextMenu(hwnd: if (builtin.os.tag == .windows) win.HWND else ?*anyopaque, tray: *Tray) void {
    if (builtin.os.tag != .windows) return;
    const menu = win.CreatePopupMenu() orelse return;
    defer _ = win.DestroyMenu(menu);

    var st_buf: [192]u8 = undefined;
    const st = tray.copyStatus(&st_buf);
    var hdr_u8_buf: [224]u8 = undefined;
    const hdr_u8 = std.fmt.bufPrint(&hdr_u8_buf, "EU5 RPC v{s} - {s}", .{ root.VERSION, st }) catch "EU5 RPC";
    var hdr_w: [256]u16 = undefined;
    if (eu5_files.utf8ToUtf16Z(hdr_u8, &hdr_w)) |hw| {
        _ = win.AppendMenuW(menu, win.MF_STRING | win.MF_GRAYED | win.MF_DISABLED, 0, hw.ptr);
    }
    _ = win.AppendMenuW(menu, win.MF_SEPARATOR, 0, null);

    const launch_flags: u32 = if (tray.game_running.load(.acquire))
        win.MF_STRING | win.MF_GRAYED | win.MF_DISABLED
    else
        win.MF_STRING;
    _ = win.AppendMenuW(menu, launch_flags, win.IDM_LAUNCH, std.unicode.utf8ToUtf16LeStringLiteral("Launch Europa Universalis V").ptr);
    _ = win.AppendMenuW(menu, win.MF_STRING, win.IDM_UPDATE, std.unicode.utf8ToUtf16LeStringLiteral("Check for Updates").ptr);
    _ = win.AppendMenuW(menu, win.MF_STRING, win.IDM_CONFIG, std.unicode.utf8ToUtf16LeStringLiteral("Open Config Folder").ptr);
    _ = win.AppendMenuW(menu, win.MF_SEPARATOR, 0, null);
    _ = win.AppendMenuW(menu, win.MF_STRING, win.IDM_QUIT, std.unicode.utf8ToUtf16LeStringLiteral("Quit (Close EU5 & RPC)").ptr);

    var pt = win.POINT{ .x = 0, .y = 0 };
    _ = win.GetCursorPos(&pt);
    _ = win.SetForegroundWindow(hwnd);
    _ = win.TrackPopupMenu(menu, win.TPM_RIGHTBUTTON | win.TPM_BOTTOMALIGN, pt.x, pt.y, 0, hwnd, null);
    _ = win.PostMessageW(hwnd, win.WM_NULL, 0, 0);
}

fn winTrayWndProc(
    hwnd: if (builtin.os.tag == .windows) win.HWND else ?*anyopaque,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    if (builtin.os.tag != .windows) return 0;
    if (g_win_tray) |tray| {
        if (g_win_taskbar_created_msg != 0 and msg == g_win_taskbar_created_msg) {
            winUpdateTrayIcon(hwnd, win.NIM_ADD, tray);
            return 0;
        }
        switch (msg) {
            win.WM_TRAYICON => {
                const ev: u32 = @intCast(@as(usize, @bitCast(lparam)) & 0xFFFF);
                if (ev == win.WM_RBUTTONUP or ev == win.WM_LBUTTONUP or ev == win.WM_CONTEXTMENU) {
                    winShowContextMenu(hwnd, tray);
                }
                return 0;
            },
            win.WM_COMMAND => {
                const id = wparam & 0xFFFF;
                switch (id) {
                    win.IDM_LAUNCH => tray.launch_requested.store(true, .release),
                    win.IDM_UPDATE => tray.check_update_requested.store(true, .release),
                    win.IDM_CONFIG => tray.open_config_requested.store(true, .release),
                    win.IDM_QUIT => tray.quit_requested.store(true, .release),
                    else => {},
                }
                return 0;
            },
            win.WM_APP_UPDATE => {
                tray.status_dirty.store(false, .release);
                winUpdateTrayIcon(hwnd, win.NIM_MODIFY, tray);
                return 0;
            },
            win.WM_APP_NOTIFY => {
                winShowNotification(hwnd, tray);
                return 0;
            },
            win.WM_APP_STOP => {
                _ = win.DestroyWindow(hwnd);
                return 0;
            },
            win.WM_DESTROY => {
                var nid = std.mem.zeroes(win.NOTIFYICONDATAW);
                nid.cbSize = @sizeOf(win.NOTIFYICONDATAW);
                nid.hWnd = hwnd;
                nid.uID = 1;
                _ = win.Shell_NotifyIconW(win.NIM_DELETE, &nid);
                win.PostQuitMessage(0);
                return 0;
            },
            else => {},
        }
    }
    return win.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn runWindowsTray(tray: *Tray) void {
    if (builtin.os.tag != .windows) return;
    g_win_tray = tray;
    defer g_win_tray = null;

    const hinst = win.GetModuleHandleW(null);
    g_win_icon = win.LoadIconW(hinst, 1) orelse win.LoadIconW(null, 32512);
    g_win_taskbar_created_msg = win.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated").ptr);

    const cls_name = std.unicode.utf8ToUtf16LeStringLiteral("Eu5RpcTrayWindowClass");
    var wc = std.mem.zeroes(win.WNDCLASSEXW);
    wc.cbSize = @sizeOf(win.WNDCLASSEXW);
    wc.lpfnWndProc = winTrayWndProc;
    wc.hInstance = hinst;
    wc.hIcon = g_win_icon;
    wc.lpszClassName = cls_name.ptr;
    _ = win.RegisterClassExW(&wc);

    const hwnd = win.CreateWindowExW(
        0,
        cls_name.ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("EU5 RPC").ptr,
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        hinst,
        null,
    ) orelse return;

    tray.win_hwnd.store(@intFromPtr(hwnd), .release);
    defer tray.win_hwnd.store(0, .release);

    winUpdateTrayIcon(hwnd, win.NIM_ADD, tray);

    var m: win.MSG = undefined;
    while (!tray.stop_flag.load(.acquire)) {
        const res = win.GetMessageW(&m, null, 0, 0);
        if (res <= 0) break;
        _ = win.TranslateMessage(&m);
        _ = win.DispatchMessageW(&m);
    }
}

// ============================================================================
// Linux D-Bus StatusNotifierItem + DBusMenu Tray (dlopen libdbus-1.so.3)
// ============================================================================

const posix = if (builtin.os.tag != .windows) struct {
    const RTLD_NOW: c_int = 2;
    extern "c" fn dlopen(filename: ?[*:0]const u8, flags: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
    extern "c" fn getpid() c_int;
    extern "c" fn getuid() u32;
    extern "c" fn fork() c_int;
    extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn _exit(status: c_int) noreturn;
} else struct {};

const DBusErrorBuf = extern struct {
    raw: [64]u8 align(8) = std.mem.zeroes([64]u8),
};

const DBusIterBuf = extern struct {
    raw: [128]u8 align(8) = std.mem.zeroes([128]u8),
};

const DBusVTable = extern struct {
    unregister_fn: ?*const fn (*anyopaque, ?*anyopaque) callconv(.c) void = null,
    message_fn: ?*const fn (*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) c_int = null,
    pad1: ?*anyopaque = null,
    pad2: ?*anyopaque = null,
    pad3: ?*anyopaque = null,
    pad4: ?*anyopaque = null,
};

const DBUS_BUS_SESSION: c_int = 0;
const DBUS_HANDLER_RESULT_HANDLED: c_int = 0;
const DBUS_HANDLER_RESULT_NOT_YET_HANDLED: c_int = 1;

const DBUS_TYPE_BOOLEAN: c_int = 'b';
const DBUS_TYPE_INT32: c_int = 'i';
const DBUS_TYPE_UINT32: c_int = 'u';
const DBUS_TYPE_STRING: c_int = 's';
const DBUS_TYPE_OBJECT_PATH: c_int = 'o';
const DBUS_TYPE_ARRAY: c_int = 'a';
const DBUS_TYPE_STRUCT: c_int = 'r';
const DBUS_TYPE_VARIANT: c_int = 'v';
const DBUS_TYPE_DICT_ENTRY: c_int = 'e';

const DBusApi = struct {
    error_init: *const fn (*DBusErrorBuf) callconv(.c) void,
    error_free: *const fn (*DBusErrorBuf) callconv(.c) void,
    error_is_set: *const fn (*const DBusErrorBuf) callconv(.c) u32,
    bus_get_private: *const fn (c_int, *DBusErrorBuf) callconv(.c) ?*anyopaque,
    bus_request_name: *const fn (*anyopaque, [*:0]const u8, u32, *DBusErrorBuf) callconv(.c) c_int,
    bus_add_match: *const fn (*anyopaque, [*:0]const u8, *DBusErrorBuf) callconv(.c) void,
    connection_set_exit_on_disconnect: *const fn (*anyopaque, u32) callconv(.c) void,
    connection_try_register_object_path: *const fn (*anyopaque, [*:0]const u8, *const DBusVTable, ?*anyopaque, *DBusErrorBuf) callconv(.c) u32,
    connection_add_filter: *const fn (*anyopaque, *const fn (*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) c_int, ?*anyopaque, ?*anyopaque) callconv(.c) u32,
    connection_read_write_dispatch: *const fn (*anyopaque, c_int) callconv(.c) u32,
    connection_send: *const fn (*anyopaque, *anyopaque, ?*u32) callconv(.c) u32,
    connection_flush: *const fn (*anyopaque) callconv(.c) void,
    connection_close: *const fn (*anyopaque) callconv(.c) void,
    connection_unref: *const fn (*anyopaque) callconv(.c) void,
    message_new_method_call: *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque,
    message_new_method_return: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    message_new_signal: *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque,
    message_unref: *const fn (*anyopaque) callconv(.c) void,
    message_is_method_call: *const fn (*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) u32,
    message_is_signal: *const fn (*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) u32,
    message_iter_init: *const fn (*anyopaque, *DBusIterBuf) callconv(.c) u32,
    message_iter_get_arg_type: *const fn (*DBusIterBuf) callconv(.c) c_int,
    message_iter_get_basic: *const fn (*DBusIterBuf, *anyopaque) callconv(.c) void,
    message_iter_next: *const fn (*DBusIterBuf) callconv(.c) u32,
    message_iter_init_append: *const fn (*anyopaque, *DBusIterBuf) callconv(.c) void,
    message_iter_append_basic: *const fn (*DBusIterBuf, c_int, *const anyopaque) callconv(.c) u32,
    message_iter_open_container: *const fn (*DBusIterBuf, c_int, ?[*:0]const u8, *DBusIterBuf) callconv(.c) u32,
    message_iter_close_container: *const fn (*DBusIterBuf, *DBusIterBuf) callconv(.c) u32,

    fn loadSym(h: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
        const ptr = posix.dlsym(h, name) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn load() ?DBusApi {
        if (builtin.os.tag == .windows) return null;
        const h = posix.dlopen("libdbus-1.so.3", posix.RTLD_NOW) orelse
            posix.dlopen("libdbus-1.so", posix.RTLD_NOW) orelse return null;

        return .{
            .error_init = loadSym(h, *const fn (*DBusErrorBuf) callconv(.c) void, "dbus_error_init") orelse return null,
            .error_free = loadSym(h, *const fn (*DBusErrorBuf) callconv(.c) void, "dbus_error_free") orelse return null,
            .error_is_set = loadSym(h, *const fn (*const DBusErrorBuf) callconv(.c) u32, "dbus_error_is_set") orelse return null,
            .bus_get_private = loadSym(h, *const fn (c_int, *DBusErrorBuf) callconv(.c) ?*anyopaque, "dbus_bus_get_private") orelse return null,
            .bus_request_name = loadSym(h, *const fn (*anyopaque, [*:0]const u8, u32, *DBusErrorBuf) callconv(.c) c_int, "dbus_bus_request_name") orelse return null,
            .bus_add_match = loadSym(h, *const fn (*anyopaque, [*:0]const u8, *DBusErrorBuf) callconv(.c) void, "dbus_bus_add_match") orelse return null,
            .connection_set_exit_on_disconnect = loadSym(h, *const fn (*anyopaque, u32) callconv(.c) void, "dbus_connection_set_exit_on_disconnect") orelse return null,
            .connection_try_register_object_path = loadSym(h, *const fn (*anyopaque, [*:0]const u8, *const DBusVTable, ?*anyopaque, *DBusErrorBuf) callconv(.c) u32, "dbus_connection_try_register_object_path") orelse return null,
            .connection_add_filter = loadSym(h, *const fn (*anyopaque, *const fn (*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) c_int, ?*anyopaque, ?*anyopaque) callconv(.c) u32, "dbus_connection_add_filter") orelse return null,
            .connection_read_write_dispatch = loadSym(h, *const fn (*anyopaque, c_int) callconv(.c) u32, "dbus_connection_read_write_dispatch") orelse return null,
            .connection_send = loadSym(h, *const fn (*anyopaque, *anyopaque, ?*u32) callconv(.c) u32, "dbus_connection_send") orelse return null,
            .connection_flush = loadSym(h, *const fn (*anyopaque) callconv(.c) void, "dbus_connection_flush") orelse return null,
            .connection_close = loadSym(h, *const fn (*anyopaque) callconv(.c) void, "dbus_connection_close") orelse return null,
            .connection_unref = loadSym(h, *const fn (*anyopaque) callconv(.c) void, "dbus_connection_unref") orelse return null,
            .message_new_method_call = loadSym(h, *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque, "dbus_message_new_method_call") orelse return null,
            .message_new_method_return = loadSym(h, *const fn (*anyopaque) callconv(.c) ?*anyopaque, "dbus_message_new_method_return") orelse return null,
            .message_new_signal = loadSym(h, *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque, "dbus_message_new_signal") orelse return null,
            .message_unref = loadSym(h, *const fn (*anyopaque) callconv(.c) void, "dbus_message_unref") orelse return null,
            .message_is_method_call = loadSym(h, *const fn (*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) u32, "dbus_message_is_method_call") orelse return null,
            .message_is_signal = loadSym(h, *const fn (*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) u32, "dbus_message_is_signal") orelse return null,
            .message_iter_init = loadSym(h, *const fn (*anyopaque, *DBusIterBuf) callconv(.c) u32, "dbus_message_iter_init") orelse return null,
            .message_iter_get_arg_type = loadSym(h, *const fn (*DBusIterBuf) callconv(.c) c_int, "dbus_message_iter_get_arg_type") orelse return null,
            .message_iter_get_basic = loadSym(h, *const fn (*DBusIterBuf, *anyopaque) callconv(.c) void, "dbus_message_iter_get_basic") orelse return null,
            .message_iter_next = loadSym(h, *const fn (*DBusIterBuf) callconv(.c) u32, "dbus_message_iter_next") orelse return null,
            .message_iter_init_append = loadSym(h, *const fn (*anyopaque, *DBusIterBuf) callconv(.c) void, "dbus_message_iter_init_append") orelse return null,
            .message_iter_append_basic = loadSym(h, *const fn (*DBusIterBuf, c_int, *const anyopaque) callconv(.c) u32, "dbus_message_iter_append_basic") orelse return null,
            .message_iter_open_container = loadSym(h, *const fn (*DBusIterBuf, c_int, ?[*:0]const u8, *DBusIterBuf) callconv(.c) u32, "dbus_message_iter_open_container") orelse return null,
            .message_iter_close_container = loadSym(h, *const fn (*DBusIterBuf, *DBusIterBuf) callconv(.c) u32, "dbus_message_iter_close_container") orelse return null,
        };
    }
};

const LinuxTrayCtx = struct {
    api: DBusApi,
    tray: *Tray,
    icon_dir_buf: [256]u8 = undefined,
    icon_dir_len: usize = 0,
    bus_name_buf: [96]u8 = undefined,
    bus_name_len: usize = 0,
    menu_revision: u32 = 1,

    fn iconDirZ(self: *const LinuxTrayCtx) [*:0]const u8 {
        return @ptrCast(&self.icon_dir_buf);
    }

    fn busNameZ(self: *const LinuxTrayCtx) [*:0]const u8 {
        return @ptrCast(&self.bus_name_buf);
    }
};

fn dbusAppendStr(api: *const DBusApi, iter: *DBusIterBuf, s: [*:0]const u8) void {
    var p = s;
    _ = api.message_iter_append_basic(iter, DBUS_TYPE_STRING, @ptrCast(&p));
}

fn dbusAppendObjPath(api: *const DBusApi, iter: *DBusIterBuf, s: [*:0]const u8) void {
    var p = s;
    _ = api.message_iter_append_basic(iter, DBUS_TYPE_OBJECT_PATH, @ptrCast(&p));
}

fn dbusAppendBool(api: *const DBusApi, iter: *DBusIterBuf, v: bool) void {
    var b: u32 = if (v) 1 else 0;
    _ = api.message_iter_append_basic(iter, DBUS_TYPE_BOOLEAN, @ptrCast(&b));
}

fn dbusAppendI32(api: *const DBusApi, iter: *DBusIterBuf, v: i32) void {
    var val = v;
    _ = api.message_iter_append_basic(iter, DBUS_TYPE_INT32, @ptrCast(&val));
}

fn dbusAppendU32(api: *const DBusApi, iter: *DBusIterBuf, v: u32) void {
    var val = v;
    _ = api.message_iter_append_basic(iter, DBUS_TYPE_UINT32, @ptrCast(&val));
}

fn dbusAppendDictStrVarStr(api: *const DBusApi, dict_iter: *DBusIterBuf, key: [*:0]const u8, val: [*:0]const u8) void {
    var entry: DBusIterBuf = .{};
    var var_iter: DBusIterBuf = .{};
    _ = api.message_iter_open_container(dict_iter, DBUS_TYPE_DICT_ENTRY, null, &entry);
    dbusAppendStr(api, &entry, key);
    _ = api.message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &var_iter);
    dbusAppendStr(api, &var_iter, val);
    _ = api.message_iter_close_container(&entry, &var_iter);
    _ = api.message_iter_close_container(dict_iter, &entry);
}

fn dbusAppendDictStrVarBool(api: *const DBusApi, dict_iter: *DBusIterBuf, key: [*:0]const u8, val: bool) void {
    var entry: DBusIterBuf = .{};
    var var_iter: DBusIterBuf = .{};
    _ = api.message_iter_open_container(dict_iter, DBUS_TYPE_DICT_ENTRY, null, &entry);
    dbusAppendStr(api, &entry, key);
    _ = api.message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "b", &var_iter);
    dbusAppendBool(api, &var_iter, val);
    _ = api.message_iter_close_container(&entry, &var_iter);
    _ = api.message_iter_close_container(dict_iter, &entry);
}

fn dbusAppendDictStrVarObjPath(api: *const DBusApi, dict_iter: *DBusIterBuf, key: [*:0]const u8, val: [*:0]const u8) void {
    var entry: DBusIterBuf = .{};
    var var_iter: DBusIterBuf = .{};
    _ = api.message_iter_open_container(dict_iter, DBUS_TYPE_DICT_ENTRY, null, &entry);
    dbusAppendStr(api, &entry, key);
    _ = api.message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "o", &var_iter);
    dbusAppendObjPath(api, &var_iter, val);
    _ = api.message_iter_close_container(&entry, &var_iter);
    _ = api.message_iter_close_container(dict_iter, &entry);
}

fn dbusAppendDictStrVarU32(api: *const DBusApi, dict_iter: *DBusIterBuf, key: [*:0]const u8, val: u32) void {
    var entry: DBusIterBuf = .{};
    var var_iter: DBusIterBuf = .{};
    _ = api.message_iter_open_container(dict_iter, DBUS_TYPE_DICT_ENTRY, null, &entry);
    dbusAppendStr(api, &entry, key);
    _ = api.message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "u", &var_iter);
    dbusAppendU32(api, &var_iter, val);
    _ = api.message_iter_close_container(&entry, &var_iter);
    _ = api.message_iter_close_container(dict_iter, &entry);
}

fn dbusAppendTooltipStruct(api: *const DBusApi, iter: *DBusIterBuf, ctx: *LinuxTrayCtx) void {
    var st_raw: [192]u8 = undefined;
    const st = ctx.tray.copyStatus(&st_raw);
    var st_z: [193]u8 = undefined;
    @memcpy(st_z[0..st.len], st);
    st_z[st.len] = 0;

    var title_buf: [64]u8 = undefined;
    const title_z = root.bufPrintZ(&title_buf, "EU5 RPC v{s}", .{root.VERSION}) catch "EU5 RPC";

    var str_iter: DBusIterBuf = .{};
    var pix_arr: DBusIterBuf = .{};
    _ = api.message_iter_open_container(iter, DBUS_TYPE_STRUCT, null, &str_iter);
    dbusAppendStr(api, &str_iter, "eu5-rpc");
    _ = api.message_iter_open_container(&str_iter, DBUS_TYPE_ARRAY, "(iiay)", &pix_arr);
    _ = api.message_iter_close_container(&str_iter, &pix_arr);
    dbusAppendStr(api, &str_iter, title_z.ptr);
    dbusAppendStr(api, &str_iter, @ptrCast(&st_z));
    _ = api.message_iter_close_container(iter, &str_iter);
}

fn dbusAppendSniProperty(api: *const DBusApi, iter: *DBusIterBuf, prop: []const u8, ctx: *LinuxTrayCtx) bool {
    var v_iter: DBusIterBuf = .{};
    if (std.mem.eql(u8, prop, "Category")) {
        _ = api.message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &v_iter);
        dbusAppendStr(api, &v_iter, "ApplicationStatus");
        _ = api.message_iter_close_container(iter, &v_iter);
        return true;
    } else if (std.mem.eql(u8, prop, "Id")) {
        _ = api.message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &v_iter);
        dbusAppendStr(api, &v_iter, "eu5-rpc");
        _ = api.message_iter_close_container(iter, &v_iter);
        return true;
    } else if (std.mem.eql(u8, prop, "Title")) {
        _ = api.message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &v_iter);
        dbusAppendStr(api, &v_iter, "EU5 RPC");
        _ = api.message_iter_close_container(iter, &v_iter);
        return true;
    } else if (std.mem.eql(u8, prop, "Status")) {
        _ = api.message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &v_iter);
        dbusAppendStr(api, &v_iter, "Active");
        _ = api.message_iter_close_container(iter, &v_iter);
        return true;
    } else if (std.mem.eql(u8, prop, "IconName")) {
        _ = api.message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &v_iter);
        dbusAppendStr(api, &v_iter, "eu5-rpc");
        _ = api.message_iter_close_container(iter, &v_iter);
        return true;
    } else if (std.mem.eql(u8, prop, "IconThemePath")) {
        _ = api.message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &v_iter);
        dbusAppendStr(api, &v_iter, ctx.iconDirZ());
        _ = api.message_iter_close_container(iter, &v_iter);
        return true;
    } else if (std.mem.eql(u8, prop, "Menu")) {
        _ = api.message_iter_open_container(iter, DBUS_TYPE_VARIANT, "o", &v_iter);
        dbusAppendObjPath(api, &v_iter, "/MenuBar");
        _ = api.message_iter_close_container(iter, &v_iter);
        return true;
    } else if (std.mem.eql(u8, prop, "ItemIsMenu")) {
        _ = api.message_iter_open_container(iter, DBUS_TYPE_VARIANT, "b", &v_iter);
        dbusAppendBool(api, &v_iter, false);
        _ = api.message_iter_close_container(iter, &v_iter);
        return true;
    } else if (std.mem.eql(u8, prop, "WindowId")) {
        _ = api.message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &v_iter);
        dbusAppendU32(api, &v_iter, 0);
        _ = api.message_iter_close_container(iter, &v_iter);
        return true;
    } else if (std.mem.eql(u8, prop, "ToolTip")) {
        _ = api.message_iter_open_container(iter, DBUS_TYPE_VARIANT, "(sa(iiay)ss)", &v_iter);
        dbusAppendTooltipStruct(api, &v_iter, ctx);
        _ = api.message_iter_close_container(iter, &v_iter);
        return true;
    } else if (std.mem.eql(u8, prop, "IconPixmap") or std.mem.eql(u8, prop, "OverlayIconPixmap") or std.mem.eql(u8, prop, "AttentionIconPixmap")) {
        var arr: DBusIterBuf = .{};
        _ = api.message_iter_open_container(iter, DBUS_TYPE_VARIANT, "a(iiay)", &v_iter);
        _ = api.message_iter_open_container(&v_iter, DBUS_TYPE_ARRAY, "(iiay)", &arr);
        _ = api.message_iter_close_container(&v_iter, &arr);
        _ = api.message_iter_close_container(iter, &v_iter);
        return true;
    } else if (std.mem.eql(u8, prop, "OverlayIconName") or std.mem.eql(u8, prop, "AttentionIconName") or std.mem.eql(u8, prop, "AttentionMovieName")) {
        _ = api.message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &v_iter);
        dbusAppendStr(api, &v_iter, "");
        _ = api.message_iter_close_container(iter, &v_iter);
        return true;
    }
    return false;
}

const SNI_INTROSPECT_XML: [:0]const u8 =
    "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\" \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n" ++
    "<node>\n" ++
    "  <interface name=\"org.kde.StatusNotifierItem\">\n" ++
    "    <property name=\"Category\" type=\"s\" access=\"read\"/>\n" ++
    "    <property name=\"Id\" type=\"s\" access=\"read\"/>\n" ++
    "    <property name=\"Title\" type=\"s\" access=\"read\"/>\n" ++
    "    <property name=\"Status\" type=\"s\" access=\"read\"/>\n" ++
    "    <property name=\"IconName\" type=\"s\" access=\"read\"/>\n" ++
    "    <property name=\"IconThemePath\" type=\"s\" access=\"read\"/>\n" ++
    "    <property name=\"Menu\" type=\"o\" access=\"read\"/>\n" ++
    "    <property name=\"ItemIsMenu\" type=\"b\" access=\"read\"/>\n" ++
    "    <property name=\"ToolTip\" type=\"(sa(iiay)ss)\" access=\"read\"/>\n" ++
    "    <method name=\"Activate\"><arg name=\"x\" type=\"i\" direction=\"in\"/><arg name=\"y\" type=\"i\" direction=\"in\"/></method>\n" ++
    "    <method name=\"SecondaryActivate\"><arg name=\"x\" type=\"i\" direction=\"in\"/><arg name=\"y\" type=\"i\" direction=\"in\"/></method>\n" ++
    "    <signal name=\"NewToolTip\"/>\n" ++
    "  </interface>\n" ++
    "  <interface name=\"org.freedesktop.DBus.Properties\">\n" ++
    "    <method name=\"Get\"><arg name=\"interface\" type=\"s\" direction=\"in\"/><arg name=\"property\" type=\"s\" direction=\"in\"/><arg name=\"value\" type=\"v\" direction=\"out\"/></method>\n" ++
    "    <method name=\"GetAll\"><arg name=\"interface\" type=\"s\" direction=\"in\"/><arg name=\"properties\" type=\"a{sv}\" direction=\"out\"/></method>\n" ++
    "  </interface>\n" ++
    "</node>\n";

const MENU_INTROSPECT_XML: [:0]const u8 =
    "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\" \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n" ++
    "<node>\n" ++
    "  <interface name=\"com.canonical.dbusmenu\">\n" ++
    "    <property name=\"Version\" type=\"u\" access=\"read\"/>\n" ++
    "    <property name=\"TextDirection\" type=\"s\" access=\"read\"/>\n" ++
    "    <property name=\"Status\" type=\"s\" access=\"read\"/>\n" ++
    "    <method name=\"GetLayout\">\n" ++
    "      <arg name=\"parentId\" type=\"i\" direction=\"in\"/>\n" ++
    "      <arg name=\"recursionDepth\" type=\"i\" direction=\"in\"/>\n" ++
    "      <arg name=\"propertyNames\" type=\"as\" direction=\"in\"/>\n" ++
    "      <arg name=\"revision\" type=\"u\" direction=\"out\"/>\n" ++
    "      <arg name=\"layout\" type=\"(ia{sv}av)\" direction=\"out\"/>\n" ++
    "    </method>\n" ++
    "    <method name=\"GetGroupProperties\">\n" ++
    "      <arg name=\"ids\" type=\"ai\" direction=\"in\"/>\n" ++
    "      <arg name=\"propertyNames\" type=\"as\" direction=\"in\"/>\n" ++
    "      <arg name=\"properties\" type=\"a(ia{sv})\" direction=\"out\"/>\n" ++
    "    </method>\n" ++
    "    <method name=\"Event\">\n" ++
    "      <arg name=\"id\" type=\"i\" direction=\"in\"/>\n" ++
    "      <arg name=\"eventId\" type=\"s\" direction=\"in\"/>\n" ++
    "      <arg name=\"data\" type=\"v\" direction=\"in\"/>\n" ++
    "      <arg name=\"timestamp\" type=\"u\" direction=\"in\"/>\n" ++
    "    </method>\n" ++
    "    <method name=\"AboutToShow\">\n" ++
    "      <arg name=\"id\" type=\"i\" direction=\"in\"/>\n" ++
    "      <arg name=\"needUpdate\" type=\"b\" direction=\"out\"/>\n" ++
    "    </method>\n" ++
    "    <signal name=\"LayoutUpdated\">\n" ++
    "      <arg name=\"revision\" type=\"u\"/>\n" ++
    "      <arg name=\"parent\" type=\"i\"/>\n" ++
    "    </signal>\n" ++
    "  </interface>\n" ++
    "</node>\n";

fn sniMessageHandler(conn: *anyopaque, msg: *anyopaque, user_data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *LinuxTrayCtx = @ptrCast(@alignCast(user_data orelse return DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
    const api = &ctx.api;

    if (api.message_is_method_call(msg, "org.freedesktop.DBus.Introspectable", "Introspect") != 0) {
        if (api.message_new_method_return(msg)) |reply| {
            defer api.message_unref(reply);
            var it: DBusIterBuf = .{};
            api.message_iter_init_append(reply, &it);
            dbusAppendStr(api, &it, SNI_INTROSPECT_XML.ptr);
            _ = api.connection_send(conn, reply, null);
            api.connection_flush(conn);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (api.message_is_method_call(msg, "org.freedesktop.DBus.Properties", "Get") != 0) {
        var in_it: DBusIterBuf = .{};
        if (api.message_iter_init(msg, &in_it) != 0 and api.message_iter_next(&in_it) != 0) {
            if (api.message_iter_get_arg_type(&in_it) == DBUS_TYPE_STRING) {
                var prop_ptr: [*:0]const u8 = "";
                api.message_iter_get_basic(&in_it, @ptrCast(&prop_ptr));
                const prop = std.mem.span(prop_ptr);
                if (api.message_new_method_return(msg)) |reply| {
                    defer api.message_unref(reply);
                    var out_it: DBusIterBuf = .{};
                    api.message_iter_init_append(reply, &out_it);
                    if (!dbusAppendSniProperty(api, &out_it, prop, ctx)) {
                        var v: DBusIterBuf = .{};
                        _ = api.message_iter_open_container(&out_it, DBUS_TYPE_VARIANT, "s", &v);
                        dbusAppendStr(api, &v, "");
                        _ = api.message_iter_close_container(&out_it, &v);
                    }
                    _ = api.connection_send(conn, reply, null);
                    api.connection_flush(conn);
                }
                return DBUS_HANDLER_RESULT_HANDLED;
            }
        }
    }

    if (api.message_is_method_call(msg, "org.freedesktop.DBus.Properties", "GetAll") != 0) {
        if (api.message_new_method_return(msg)) |reply| {
            defer api.message_unref(reply);
            var out_it: DBusIterBuf = .{};
            var dict: DBusIterBuf = .{};
            api.message_iter_init_append(reply, &out_it);
            _ = api.message_iter_open_container(&out_it, DBUS_TYPE_ARRAY, "{sv}", &dict);
            dbusAppendDictStrVarStr(api, &dict, "Category", "ApplicationStatus");
            dbusAppendDictStrVarStr(api, &dict, "Id", "eu5-rpc");
            dbusAppendDictStrVarStr(api, &dict, "Title", "EU5 RPC");
            dbusAppendDictStrVarStr(api, &dict, "Status", "Active");
            dbusAppendDictStrVarStr(api, &dict, "IconName", "eu5-rpc");
            dbusAppendDictStrVarStr(api, &dict, "IconThemePath", ctx.iconDirZ());
            dbusAppendDictStrVarObjPath(api, &dict, "Menu", "/MenuBar");
            dbusAppendDictStrVarBool(api, &dict, "ItemIsMenu", false);
            {
                var entry: DBusIterBuf = .{};
                var v_iter: DBusIterBuf = .{};
                _ = api.message_iter_open_container(&dict, DBUS_TYPE_DICT_ENTRY, null, &entry);
                dbusAppendStr(api, &entry, "ToolTip");
                _ = api.message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "(sa(iiay)ss)", &v_iter);
                dbusAppendTooltipStruct(api, &v_iter, ctx);
                _ = api.message_iter_close_container(&entry, &v_iter);
                _ = api.message_iter_close_container(&dict, &entry);
            }
            _ = api.message_iter_close_container(&out_it, &dict);
            _ = api.connection_send(conn, reply, null);
            api.connection_flush(conn);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (api.message_is_method_call(msg, "org.kde.StatusNotifierItem", "Activate") != 0 or
        api.message_is_method_call(msg, "org.kde.StatusNotifierItem", "SecondaryActivate") != 0 or
        api.message_is_method_call(msg, "org.kde.StatusNotifierItem", "ContextMenu") != 0 or
        api.message_is_method_call(msg, "org.kde.StatusNotifierItem", "Scroll") != 0)
    {
        if (api.message_new_method_return(msg)) |reply| {
            defer api.message_unref(reply);
            _ = api.connection_send(conn, reply, null);
            api.connection_flush(conn);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

fn dbusAppendMenuItem(
    api: *const DBusApi,
    children_arr: *DBusIterBuf,
    id: i32,
    label: ?[*:0]const u8,
    is_separator: bool,
    enabled: bool,
) void {
    var v_iter: DBusIterBuf = .{};
    var item_struct: DBusIterBuf = .{};
    var props: DBusIterBuf = .{};
    var kids: DBusIterBuf = .{};

    _ = api.message_iter_open_container(children_arr, DBUS_TYPE_VARIANT, "(ia{sv}av)", &v_iter);
    _ = api.message_iter_open_container(&v_iter, DBUS_TYPE_STRUCT, null, &item_struct);
    dbusAppendI32(api, &item_struct, id);
    _ = api.message_iter_open_container(&item_struct, DBUS_TYPE_ARRAY, "{sv}", &props);
    if (is_separator) {
        dbusAppendDictStrVarStr(api, &props, "type", "separator");
    } else {
        if (label) |lbl| dbusAppendDictStrVarStr(api, &props, "label", lbl);
        dbusAppendDictStrVarBool(api, &props, "enabled", enabled);
        dbusAppendDictStrVarBool(api, &props, "visible", true);
    }
    _ = api.message_iter_close_container(&item_struct, &props);
    _ = api.message_iter_open_container(&item_struct, DBUS_TYPE_ARRAY, "v", &kids);
    _ = api.message_iter_close_container(&item_struct, &kids);
    _ = api.message_iter_close_container(&v_iter, &item_struct);
    _ = api.message_iter_close_container(children_arr, &v_iter);
}

fn menuMessageHandler(conn: *anyopaque, msg: *anyopaque, user_data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *LinuxTrayCtx = @ptrCast(@alignCast(user_data orelse return DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
    const api = &ctx.api;

    if (api.message_is_method_call(msg, "org.freedesktop.DBus.Introspectable", "Introspect") != 0) {
        if (api.message_new_method_return(msg)) |reply| {
            defer api.message_unref(reply);
            var it: DBusIterBuf = .{};
            api.message_iter_init_append(reply, &it);
            dbusAppendStr(api, &it, MENU_INTROSPECT_XML.ptr);
            _ = api.connection_send(conn, reply, null);
            api.connection_flush(conn);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (api.message_is_method_call(msg, "org.freedesktop.DBus.Properties", "Get") != 0) {
        var in_it: DBusIterBuf = .{};
        if (api.message_iter_init(msg, &in_it) != 0 and api.message_iter_next(&in_it) != 0) {
            if (api.message_iter_get_arg_type(&in_it) == DBUS_TYPE_STRING) {
                var prop_ptr: [*:0]const u8 = "";
                api.message_iter_get_basic(&in_it, @ptrCast(&prop_ptr));
                const prop = std.mem.span(prop_ptr);
                if (api.message_new_method_return(msg)) |reply| {
                    defer api.message_unref(reply);
                    var out_it: DBusIterBuf = .{};
                    var v: DBusIterBuf = .{};
                    api.message_iter_init_append(reply, &out_it);
                    if (std.mem.eql(u8, prop, "Version")) {
                        _ = api.message_iter_open_container(&out_it, DBUS_TYPE_VARIANT, "u", &v);
                        dbusAppendU32(api, &v, 3);
                        _ = api.message_iter_close_container(&out_it, &v);
                    } else if (std.mem.eql(u8, prop, "TextDirection")) {
                        _ = api.message_iter_open_container(&out_it, DBUS_TYPE_VARIANT, "s", &v);
                        dbusAppendStr(api, &v, "ltr");
                        _ = api.message_iter_close_container(&out_it, &v);
                    } else if (std.mem.eql(u8, prop, "Status")) {
                        _ = api.message_iter_open_container(&out_it, DBUS_TYPE_VARIANT, "s", &v);
                        dbusAppendStr(api, &v, "normal");
                        _ = api.message_iter_close_container(&out_it, &v);
                    } else {
                        var arr: DBusIterBuf = .{};
                        _ = api.message_iter_open_container(&out_it, DBUS_TYPE_VARIANT, "as", &v);
                        _ = api.message_iter_open_container(&v, DBUS_TYPE_ARRAY, "s", &arr);
                        _ = api.message_iter_close_container(&v, &arr);
                        _ = api.message_iter_close_container(&out_it, &v);
                    }
                    _ = api.connection_send(conn, reply, null);
                    api.connection_flush(conn);
                }
                return DBUS_HANDLER_RESULT_HANDLED;
            }
        }
    }

    if (api.message_is_method_call(msg, "org.freedesktop.DBus.Properties", "GetAll") != 0) {
        if (api.message_new_method_return(msg)) |reply| {
            defer api.message_unref(reply);
            var out_it: DBusIterBuf = .{};
            var dict: DBusIterBuf = .{};
            api.message_iter_init_append(reply, &out_it);
            _ = api.message_iter_open_container(&out_it, DBUS_TYPE_ARRAY, "{sv}", &dict);
            dbusAppendDictStrVarU32(api, &dict, "Version", 3);
            dbusAppendDictStrVarStr(api, &dict, "TextDirection", "ltr");
            dbusAppendDictStrVarStr(api, &dict, "Status", "normal");
            _ = api.message_iter_close_container(&out_it, &dict);
            _ = api.connection_send(conn, reply, null);
            api.connection_flush(conn);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (api.message_is_method_call(msg, "com.canonical.dbusmenu", "GetLayout") != 0) {
        if (api.message_new_method_return(msg)) |reply| {
            defer api.message_unref(reply);
            var out_it: DBusIterBuf = .{};
            var root_struct: DBusIterBuf = .{};
            var root_props: DBusIterBuf = .{};
            var children: DBusIterBuf = .{};

            var st_raw: [192]u8 = undefined;
            const st = ctx.tray.copyStatus(&st_raw);
            var hdr_buf: [240]u8 = undefined;
            const hdr_z = root.bufPrintZ(&hdr_buf, "EU5 RPC v{s} - {s}", .{ root.VERSION, st }) catch "EU5 RPC";
            const running = ctx.tray.game_running.load(.acquire);

            api.message_iter_init_append(reply, &out_it);
            dbusAppendU32(api, &out_it, ctx.menu_revision);
            _ = api.message_iter_open_container(&out_it, DBUS_TYPE_STRUCT, null, &root_struct);
            dbusAppendI32(api, &root_struct, 0);
            _ = api.message_iter_open_container(&root_struct, DBUS_TYPE_ARRAY, "{sv}", &root_props);
            dbusAppendDictStrVarStr(api, &root_props, "children-display", "submenu");
            _ = api.message_iter_close_container(&root_struct, &root_props);

            _ = api.message_iter_open_container(&root_struct, DBUS_TYPE_ARRAY, "v", &children);
            dbusAppendMenuItem(api, &children, 1, hdr_z.ptr, false, false);
            dbusAppendMenuItem(api, &children, 2, null, true, false);
            dbusAppendMenuItem(api, &children, 3, "Launch Europa Universalis V", false, !running);
            dbusAppendMenuItem(api, &children, 4, "Check for Updates", false, true);
            dbusAppendMenuItem(api, &children, 5, "Open Config Folder", false, true);
            dbusAppendMenuItem(api, &children, 6, null, true, false);
            dbusAppendMenuItem(api, &children, 7, "Quit (Close EU5 & RPC)", false, true);
            _ = api.message_iter_close_container(&root_struct, &children);
            _ = api.message_iter_close_container(&out_it, &root_struct);

            _ = api.connection_send(conn, reply, null);
            api.connection_flush(conn);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (api.message_is_method_call(msg, "com.canonical.dbusmenu", "GetGroupProperties") != 0) {
        if (api.message_new_method_return(msg)) |reply| {
            defer api.message_unref(reply);
            var out_it: DBusIterBuf = .{};
            var arr: DBusIterBuf = .{};
            api.message_iter_init_append(reply, &out_it);
            _ = api.message_iter_open_container(&out_it, DBUS_TYPE_ARRAY, "(ia{sv})", &arr);
            _ = api.message_iter_close_container(&out_it, &arr);
            _ = api.connection_send(conn, reply, null);
            api.connection_flush(conn);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (api.message_is_method_call(msg, "com.canonical.dbusmenu", "AboutToShow") != 0) {
        if (api.message_new_method_return(msg)) |reply| {
            defer api.message_unref(reply);
            var out_it: DBusIterBuf = .{};
            api.message_iter_init_append(reply, &out_it);
            dbusAppendBool(api, &out_it, true);
            _ = api.connection_send(conn, reply, null);
            api.connection_flush(conn);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    if (api.message_is_method_call(msg, "com.canonical.dbusmenu", "Event") != 0) {
        var in_it: DBusIterBuf = .{};
        if (api.message_iter_init(msg, &in_it) != 0 and api.message_iter_get_arg_type(&in_it) == DBUS_TYPE_INT32) {
            var item_id: i32 = 0;
            api.message_iter_get_basic(&in_it, @ptrCast(&item_id));
            if (api.message_iter_next(&in_it) != 0 and api.message_iter_get_arg_type(&in_it) == DBUS_TYPE_STRING) {
                var ev_ptr: [*:0]const u8 = "";
                api.message_iter_get_basic(&in_it, @ptrCast(&ev_ptr));
                if (std.mem.eql(u8, std.mem.span(ev_ptr), "clicked")) {
                    switch (item_id) {
                        3 => ctx.tray.launch_requested.store(true, .release),
                        4 => ctx.tray.check_update_requested.store(true, .release),
                        5 => ctx.tray.open_config_requested.store(true, .release),
                        7 => ctx.tray.quit_requested.store(true, .release),
                        else => {},
                    }
                }
            }
        }
        if (api.message_new_method_return(msg)) |reply| {
            defer api.message_unref(reply);
            _ = api.connection_send(conn, reply, null);
            api.connection_flush(conn);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

fn registerWithWatcher(api: *const DBusApi, conn: *anyopaque) void {
    const call = api.message_new_method_call(
        "org.kde.StatusNotifierWatcher",
        "/StatusNotifierWatcher",
        "org.kde.StatusNotifierWatcher",
        "RegisterStatusNotifierItem",
    ) orelse return;
    defer api.message_unref(call);

    var it: DBusIterBuf = .{};
    api.message_iter_init_append(call, &it);
    dbusAppendStr(api, &it, "/StatusNotifierItem");
    _ = api.connection_send(conn, call, null);
    api.connection_flush(conn);
}

fn emitSniStatusUpdated(api: *const DBusApi, conn: *anyopaque, ctx: *LinuxTrayCtx) void {
    if (api.message_new_signal("/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewToolTip")) |sig| {
        defer api.message_unref(sig);
        _ = api.connection_send(conn, sig, null);
    }
    ctx.menu_revision += 1;
    if (api.message_new_signal("/MenuBar", "com.canonical.dbusmenu", "LayoutUpdated")) |sig| {
        defer api.message_unref(sig);
        var it: DBusIterBuf = .{};
        api.message_iter_init_append(sig, &it);
        dbusAppendU32(api, &it, ctx.menu_revision);
        dbusAppendI32(api, &it, 0);
        _ = api.connection_send(conn, sig, null);
    }
    api.connection_flush(conn);
}

fn sendLinuxDesktopNotification(api: *const DBusApi, conn: *anyopaque, title: []const u8, body: []const u8) void {
    const call = api.message_new_method_call(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
    ) orelse return;
    defer api.message_unref(call);

    var t_z: [65]u8 = undefined;
    const tn = @min(title.len, 64);
    @memcpy(t_z[0..tn], title[0..tn]);
    t_z[tn] = 0;

    var b_z: [257]u8 = undefined;
    const bn = @min(body.len, 256);
    @memcpy(b_z[0..bn], body[0..bn]);
    b_z[bn] = 0;

    var it: DBusIterBuf = .{};
    var acts: DBusIterBuf = .{};
    var hints: DBusIterBuf = .{};
    api.message_iter_init_append(call, &it);
    dbusAppendStr(api, &it, "EU5 RPC");
    dbusAppendU32(api, &it, 0);
    dbusAppendStr(api, &it, "eu5-rpc");
    dbusAppendStr(api, &it, @ptrCast(&t_z));
    dbusAppendStr(api, &it, @ptrCast(&b_z));
    _ = api.message_iter_open_container(&it, DBUS_TYPE_ARRAY, "s", &acts);
    _ = api.message_iter_close_container(&it, &acts);
    _ = api.message_iter_open_container(&it, DBUS_TYPE_ARRAY, "{sv}", &hints);
    _ = api.message_iter_close_container(&it, &hints);
    dbusAppendI32(api, &it, 5000);

    _ = api.connection_send(conn, call, null);
    api.connection_flush(conn);
}

fn watcherFilterCb(conn: *anyopaque, msg: *anyopaque, user_data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *LinuxTrayCtx = @ptrCast(@alignCast(user_data orelse return DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
    const api = &ctx.api;
    if (api.message_is_signal(msg, "org.freedesktop.DBus", "NameOwnerChanged") != 0) {
        var it: DBusIterBuf = .{};
        if (api.message_iter_init(msg, &it) != 0 and api.message_iter_get_arg_type(&it) == DBUS_TYPE_STRING) {
            var name_ptr: [*:0]const u8 = "";
            api.message_iter_get_basic(&it, @ptrCast(&name_ptr));
            if (std.mem.eql(u8, std.mem.span(name_ptr), "org.kde.StatusNotifierWatcher")) {
                if (api.message_iter_next(&it) != 0 and api.message_iter_next(&it) != 0 and
                    api.message_iter_get_arg_type(&it) == DBUS_TYPE_STRING)
                {
                    var new_owner: [*:0]const u8 = "";
                    api.message_iter_get_basic(&it, @ptrCast(&new_owner));
                    if (std.mem.span(new_owner).len > 0) {
                        registerWithWatcher(api, conn);
                    }
                }
            }
        }
    }
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

fn runLinuxTray(tray: *Tray) void {
    if (builtin.os.tag == .windows) return;
    const api = DBusApi.load() orelse return;

    var err: DBusErrorBuf = .{};
    api.error_init(&err);
    defer api.error_free(&err);

    const conn = api.bus_get_private(DBUS_BUS_SESSION, &err) orelse return;
    defer {
        api.connection_close(conn);
        api.connection_unref(conn);
    }
    api.connection_set_exit_on_disconnect(conn, 0);

    var ctx = LinuxTrayCtx{
        .api = api,
        .tray = tray,
    };

    // Write embedded icon.png to runtime icon dir so KDE/GNOME/XFCE/Waybar display the exact icon immediately
    var env_buf: [256]u8 = undefined;
    const icon_dir = blk: {
        if (eu5_files.getEnvUtf8("XDG_RUNTIME_DIR", &env_buf)) |rt| {
            const trimmed = std.mem.trimEnd(u8, rt, "/");
            if (trimmed.len > 0) {
                if (root.bufPrintZ(&ctx.icon_dir_buf, "{s}/eu5-rpc-icons", .{trimmed})) |p| break :blk p else |_| {}
            }
        }
        break :blk root.bufPrintZ(&ctx.icon_dir_buf, "/tmp/eu5-rpc-icons-{d}", .{posix.getuid()}) catch return;
    };
    ctx.icon_dir_len = icon_dir.len;
    eu5_files.ensureDirRecursive(icon_dir);
    var icon_file_buf: [320]u8 = undefined;
    if (root.bufPrintZ(&icon_file_buf, "{s}/eu5-rpc.png", .{icon_dir})) |ifp| {
        _ = eu5_files.writeFileAll(ifp.ptr, ICON_PNG);
    } else |_| {}

    const bus_name = root.bufPrintZ(&ctx.bus_name_buf, "org.kde.StatusNotifierItem-{d}-1", .{posix.getpid()}) catch return;
    ctx.bus_name_len = bus_name.len;
    _ = api.bus_request_name(conn, bus_name.ptr, 0, &err);
    api.error_free(&err);
    api.error_init(&err);

    const sni_vt = DBusVTable{ .message_fn = sniMessageHandler };
    const menu_vt = DBusVTable{ .message_fn = menuMessageHandler };
    _ = api.connection_try_register_object_path(conn, "/StatusNotifierItem", &sni_vt, &ctx, &err);
    api.error_free(&err);
    api.error_init(&err);
    _ = api.connection_try_register_object_path(conn, "/MenuBar", &menu_vt, &ctx, &err);
    api.error_free(&err);
    api.error_init(&err);

    // Watch for StatusNotifierWatcher restarts (e.g. plasmashell / GNOME Shell restart) so the tray stays persistent
    api.bus_add_match(conn, "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.kde.StatusNotifierWatcher'", &err);
    api.error_free(&err);
    api.error_init(&err);
    _ = api.connection_add_filter(conn, watcherFilterCb, &ctx, null);

    registerWithWatcher(&api, conn);

    while (!tray.stop_flag.load(.acquire)) {
        if (tray.status_dirty.swap(false, .acq_rel)) {
            emitSniStatusUpdated(&api, conn, &ctx);
        }
        var t_buf: [64]u8 = undefined;
        var b_buf: [256]u8 = undefined;
        if (tray.takeNotify(&t_buf, &b_buf)) |note| {
            sendLinuxDesktopNotification(&api, conn, note.title, note.body);
        }
        if (api.connection_read_write_dispatch(conn, 100) == 0) {
            break;
        }
    }
}

test "Tray controller safely tracks status updates and actions" {
    var t = Tray.init();
    t.updateStatus("Playing as France (1454)", true);
    try std.testing.expectEqual(true, t.game_running.load(.acquire));

    var buf: [192]u8 = undefined;
    try std.testing.expectEqualStrings("Playing as France (1454)", t.copyStatus(&buf));
    try std.testing.expectEqual(TrayAction.none, t.pollAction());

    t.quit_requested.store(true, .release);
    try std.testing.expectEqual(TrayAction.quit_all, t.pollAction());
    try std.testing.expectEqual(TrayAction.none, t.pollAction());
}
