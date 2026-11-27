// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const builtin = @import("builtin");
const eu5 = @import("eu5_rpc");

extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;
extern "c" fn time(tloc: ?*i64) i64;

const win = if (builtin.os.tag == .windows) struct {
    const HANDLE = ?*anyopaque;
    const ERROR_ALREADY_EXISTS: u32 = 183;
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
    extern "kernel32" fn CreateMutexA(
        lpMutexAttributes: ?*anyopaque,
        bInitialOwner: i32,
        lpName: [*:0]const u8,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
} else struct {};

const posix = if (builtin.os.tag != .windows) struct {
    const FILE = anyopaque;
    const O_CREAT: c_int = 0o100;
    const O_RDWR: c_int = 2;
    const F_SETLK: c_int = 6;
    const F_WRLCK: i16 = 1;
    const SEEK_SET: i16 = 0;
    const Flock = extern struct {
        l_type: i16,
        l_whence: i16,
        l_start: i64,
        l_len: i64,
        l_pid: i32,
    };
    const SIGINT: c_int = 2;
    const SIGPIPE: c_int = 13;
    const SIGTERM: c_int = 15;
    const SIG_IGN: usize = 1;
    extern "c" fn signal(sig: c_int, handler: usize) usize;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn getuid() u32;
    extern "c" fn usleep(usec: u32) c_int;
    extern "c" fn open(pathname: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn chmod(pathname: [*:0]const u8, mode: u32) c_int;
    extern "c" fn unlink(pathname: [*:0]const u8) c_int;
    extern "c" fn rmdir(pathname: [*:0]const u8) c_int;
    extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
    extern "c" fn readlink(pathname: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;
    extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
    extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;
    extern "c" fn fclose(stream: *FILE) c_int;
    extern "c" fn fork() c_int;
    extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn _exit(status: c_int) noreturn;
} else struct {};

var g_stop = std.atomic.Value(bool).init(false);
var g_update_in_progress = std.atomic.Value(bool).init(false);

fn handleStopSignal(_: c_int) callconv(.c) void {
    g_stop.store(true, .release);
}

fn sleepMs(ms: u32, tray: *eu5.tray.Tray) void {
    var remaining: u32 = ms;
    while (remaining > 0 and !g_stop.load(.acquire)) {
        // Wake promptly if the user clicked an item in the tray menu
        if (tray.quit_requested.load(.acquire) or
            tray.launch_requested.load(.acquire) or
            tray.check_update_requested.load(.acquire) or
            tray.open_config_requested.load(.acquire))
        {
            return;
        }
        const step: u32 = @min(remaining, 100);
        if (builtin.os.tag == .windows) {
            win.Sleep(step);
        } else {
            _ = posix.usleep(step * 1000);
        }
        remaining -= step;
    }
}

fn acquireSingleInstance() bool {
    if (builtin.os.tag == .windows) {
        const mtx = win.CreateMutexA(null, 1, "Local\\Eu5RpcZigSingleInstance");
        if (mtx == null) return false;
        if (win.GetLastError() == win.ERROR_ALREADY_EXISTS) {
            _ = win.CloseHandle(mtx);
            return false;
        }
        return true;
    } else {
        var lock_buf: [256]u8 = undefined;
        const lock_path = blk: {
            if (posix.getenv("XDG_RUNTIME_DIR")) |rt_ptr| {
                const rt = std.mem.trimEnd(u8, std.mem.span(rt_ptr), "/");
                if (rt.len > 0) {
                    if (eu5.bufPrintZ(&lock_buf, "{s}/eu5-rpc.lock", .{rt})) |p| break :blk p else |_| {}
                }
            }
            break :blk eu5.bufPrintZ(&lock_buf, "/tmp/eu5-rpc-{d}.lock", .{posix.getuid()}) catch "/tmp/eu5-rpc.lock";
        };
        const fd = posix.open(lock_path.ptr, posix.O_CREAT | posix.O_RDWR, @as(c_uint, 0o600));
        if (fd < 0) return true;
        var fl = std.mem.zeroes(posix.Flock);
        fl.l_type = posix.F_WRLCK;
        fl.l_whence = posix.SEEK_SET;
        if (posix.fcntl(fd, posix.F_SETLK, &fl) < 0) {
            _ = posix.close(fd);
            return false;
        }
        return true;
    }
}

fn writeFileLinux(path_z: [*:0]const u8, data: []const u8) bool {
    if (builtin.os.tag == .windows) return false;
    const fp = posix.fopen(path_z, "wb") orelse return false;
    defer _ = posix.fclose(fp);
    if (data.len == 0) return true;
    return posix.fwrite(data.ptr, 1, data.len, fp) == data.len;
}

fn copyFileLinux(src_z: [*:0]const u8, dst_z: [*:0]const u8) bool {
    if (builtin.os.tag == .windows) return false;
    const in_fp = posix.fopen(src_z, "rb") orelse return false;
    defer _ = posix.fclose(in_fp);
    const out_fp = posix.fopen(dst_z, "wb") orelse return false;
    defer _ = posix.fclose(out_fp);

    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = posix.fread(&chunk, 1, chunk.len, in_fp);
        if (n == 0) break;
        if (posix.fwrite(&chunk, 1, n, out_fp) != n) return false;
    }
    return true;
}

fn runQuietHelperLinux(argv: [*:null]const ?[*:0]const u8) void {
    if (builtin.os.tag == .windows) return;
    const pid = posix.fork();
    if (pid == 0) {
        _ = posix.execvp(argv[0].?, argv);
        posix._exit(1);
    } else if (pid > 0) {
        var status: c_int = 0;
        _ = posix.waitpid(pid, &status, 0);
    }
}

fn installLinux() void {
    if (builtin.os.tag == .windows) {
        _ = printf("On Windows, run EU5-RPC-Setup-v%s-win64.exe to install.\n", eu5.VERSION.ptr);
        return;
    }

    const home_ptr = posix.getenv("HOME") orelse {
        _ = printf("Error: HOME environment variable is not set.\n");
        return;
    };
    const home = std.mem.trimEnd(u8, std.mem.span(home_ptr), "/");
    const explicit_prefix = if (posix.getenv("PREFIX")) |p| std.mem.trimEnd(u8, std.mem.span(p), "/") else "";

    var base_buf: [512]u8 = undefined;
    const base_prefix = if (explicit_prefix.len > 0)
        explicit_prefix
    else
        eu5.bufPrintZ(&base_buf, "{s}/.local", .{home}) catch return;

    var data_home_buf: [512]u8 = undefined;
    const share_dir = blk: {
        if (explicit_prefix.len == 0) {
            if (posix.getenv("XDG_DATA_HOME")) |xdg_ptr| {
                const xdg = std.mem.trimEnd(u8, std.mem.span(xdg_ptr), "/");
                if (xdg.len > 0) break :blk xdg;
            }
        }
        break :blk eu5.bufPrintZ(&data_home_buf, "{s}/share", .{base_prefix}) catch return;
    };

    var app_dir_buf: [560]u8 = undefined;
    var bin_dir_buf: [560]u8 = undefined;
    var desktop_dir_buf: [560]u8 = undefined;
    var icon_dir_buf: [560]u8 = undefined;

    const app_dir = eu5.bufPrintZ(&app_dir_buf, "{s}/eu5-rpc", .{share_dir}) catch return;
    const bin_dir = eu5.bufPrintZ(&bin_dir_buf, "{s}/bin", .{base_prefix}) catch return;
    const desktop_dir = eu5.bufPrintZ(&desktop_dir_buf, "{s}/applications", .{share_dir}) catch return;
    const icon_dir = eu5.bufPrintZ(&icon_dir_buf, "{s}/icons/hicolor/256x256/apps", .{share_dir}) catch return;

    eu5.eu5_files.ensureDirRecursive(app_dir);
    eu5.eu5_files.ensureDirRecursive(bin_dir);
    eu5.eu5_files.ensureDirRecursive(desktop_dir);
    eu5.eu5_files.ensureDirRecursive(icon_dir);

    // Clean up legacy Ruby installation folders on upgrade
    eu5.updater.cleanupLegacyRubyLinux(app_dir);

    var self_buf: [512]u8 = undefined;
    const self_len = posix.readlink("/proc/self/exe", &self_buf, self_buf.len - 1);
    if (self_len <= 0) {
        _ = printf("Error: could not resolve current executable path.\n");
        return;
    }
    self_buf[@intCast(self_len)] = 0;

    var dst_bin_buf: [600]u8 = undefined;
    const dst_bin = eu5.bufPrintZ(&dst_bin_buf, "{s}/eu5-rpc", .{app_dir}) catch return;
    if (!copyFileLinux(@ptrCast(&self_buf), dst_bin.ptr)) {
        _ = printf("Error: failed to copy eu5-rpc binary to %s\n", dst_bin.ptr);
        return;
    }
    _ = posix.chmod(dst_bin.ptr, 0o755);

    var link_buf: [600]u8 = undefined;
    const link_path = eu5.bufPrintZ(&link_buf, "{s}/eu5-rpc", .{bin_dir}) catch return;
    _ = posix.unlink(link_path.ptr);
    _ = posix.symlink(dst_bin.ptr, link_path.ptr);

    const icon_png = @embedFile("icon_png");
    var icon_dst_buf: [600]u8 = undefined;
    const icon_dst = eu5.bufPrintZ(&icon_dst_buf, "{s}/eu5-rpc.png", .{icon_dir}) catch return;
    _ = writeFileLinux(icon_dst.ptr, icon_png);

    var desktop_dst_buf: [600]u8 = undefined;
    const desktop_dst = eu5.bufPrintZ(&desktop_dst_buf, "{s}/eu5-rpc.desktop", .{desktop_dir}) catch return;
    var desktop_content_buf: [1024]u8 = undefined;
    const has_spaces = std.mem.indexOfScalar(u8, link_path, ' ') != null;
    const desktop_content = if (has_spaces)
        std.fmt.bufPrint(
            &desktop_content_buf,
            "[Desktop Entry]\n" ++
                "Version=1.0\n" ++
                "Type=Application\n" ++
                "Name=EU5 RPC\n" ++
                "Comment=Discord Rich Presence for Europa Universalis V\n" ++
                "Exec=\"{s}\"\n" ++
                "Icon=eu5-rpc\n" ++
                "Terminal=false\n" ++
                "Categories=Game;Utility;\n" ++
                "StartupNotify=false\n",
            .{link_path},
        ) catch return
    else
        std.fmt.bufPrint(
            &desktop_content_buf,
            "[Desktop Entry]\n" ++
                "Version=1.0\n" ++
                "Type=Application\n" ++
                "Name=EU5 RPC\n" ++
                "Comment=Discord Rich Presence for Europa Universalis V\n" ++
                "Exec={s}\n" ++
                "Icon=eu5-rpc\n" ++
                "Terminal=false\n" ++
                "Categories=Game;Utility;\n" ++
                "StartupNotify=false\n",
            .{link_path},
        ) catch return;
    _ = writeFileLinux(desktop_dst.ptr, desktop_content);

    const upd_db = [_:null]?[*:0]const u8{ "update-desktop-database", desktop_dir.ptr };
    runQuietHelperLinux(&upd_db);

    _ = printf("Installed EU5 RPC to %s\nRun with: %s\n", app_dir.ptr, link_path.ptr);
}

fn uninstallLinux() void {
    if (builtin.os.tag == .windows) {
        _ = printf("On Windows, uninstall via Settings -> Apps or EU5-RPC-Setup.exe --uninstall.\n");
        return;
    }
    const home_ptr = posix.getenv("HOME") orelse return;
    const home = std.mem.trimEnd(u8, std.mem.span(home_ptr), "/");
    const explicit_prefix = if (posix.getenv("PREFIX")) |p| std.mem.trimEnd(u8, std.mem.span(p), "/") else "";

    var base_buf: [512]u8 = undefined;
    const base_prefix = if (explicit_prefix.len > 0)
        explicit_prefix
    else
        eu5.bufPrintZ(&base_buf, "{s}/.local", .{home}) catch return;

    var data_home_buf: [512]u8 = undefined;
    const share_dir = blk: {
        if (explicit_prefix.len == 0) {
            if (posix.getenv("XDG_DATA_HOME")) |xdg_ptr| {
                const xdg = std.mem.trimEnd(u8, std.mem.span(xdg_ptr), "/");
                if (xdg.len > 0) break :blk xdg;
            }
        }
        break :blk eu5.bufPrintZ(&data_home_buf, "{s}/share", .{base_prefix}) catch return;
    };

    var p_buf: [600]u8 = undefined;
    if (eu5.bufPrintZ(&p_buf, "{s}/bin/eu5-rpc", .{base_prefix})) |p| _ = posix.unlink(p.ptr) else |_| {}
    if (eu5.bufPrintZ(&p_buf, "{s}/applications/eu5-rpc.desktop", .{share_dir})) |p| _ = posix.unlink(p.ptr) else |_| {}
    if (eu5.bufPrintZ(&p_buf, "{s}/icons/hicolor/256x256/apps/eu5-rpc.png", .{share_dir})) |p| _ = posix.unlink(p.ptr) else |_| {}
    if (eu5.bufPrintZ(&p_buf, "{s}/eu5-rpc/eu5-rpc", .{share_dir})) |p| _ = posix.unlink(p.ptr) else |_| {}
    if (eu5.bufPrintZ(&p_buf, "{s}/eu5-rpc", .{share_dir})) |p| {
        eu5.updater.cleanupLegacyRubyLinux(p);
        _ = posix.rmdir(p.ptr);
    } else |_| {}
    _ = printf("Uninstalled EU5 RPC.\n");
}

const UpdateTaskArgs = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    tray: *eu5.tray.Tray,
    notify_up_to_date: bool,
};

fn runBackgroundUpdateCheck(args: UpdateTaskArgs) void {
    defer g_update_in_progress.store(false, .release);

    const res = eu5.updater.checkForUpdate(args.alloc, args.io);
    switch (res.status) {
        .update_available, .migrating_from_ruby => {
            if (res.release) |rel| {
                var msg_buf: [200]u8 = undefined;
                const msg = if (res.legacy_ruby_detected)
                    std.fmt.bufPrint(&msg_buf, "Migrating legacy Ruby install to Zig {s}...", .{rel.tagName()}) catch "Updating EU5 RPC..."
                else
                    std.fmt.bufPrint(&msg_buf, "Updating EU5 RPC to {s}...", .{rel.tagName()}) catch "Updating EU5 RPC...";
                args.tray.notify("EU5 RPC Update", msg);

                if (eu5.updater.applyUpdate(args.alloc, args.io, &rel)) {
                    g_stop.store(true, .release);
                } else {
                    var fail_buf: [220]u8 = undefined;
                    const fail_msg = std.fmt.bufPrint(&fail_buf, "Update {s} available at {s}", .{
                        rel.tagName(),
                        eu5.GITHUB_RELEASES_LATEST_URL,
                    }) catch "Update available on GitHub Releases";
                    args.tray.notify("EU5 RPC Update", fail_msg);
                }
            }
        },
        .up_to_date => {
            if (args.notify_up_to_date) {
                var msg_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "EU5 RPC v{s} is up to date.", .{eu5.VERSION}) catch "EU5 RPC is up to date.";
                args.tray.notify("EU5 RPC", msg);
            }
        },
        .check_failed => {
            if (args.notify_up_to_date) {
                args.tray.notify("EU5 RPC Update", "Could not reach GitHub Releases. Try again later.");
            }
        },
        else => {},
    }
}

fn triggerBackgroundUpdate(alloc: std.mem.Allocator, io: std.Io, tray: *eu5.tray.Tray, notify_up_to_date: bool) void {
    if (g_update_in_progress.swap(true, .acq_rel)) return;
    if (std.Thread.spawn(.{}, runBackgroundUpdateCheck, .{UpdateTaskArgs{
        .alloc = alloc,
        .io = io,
        .tray = tray,
        .notify_up_to_date = notify_up_to_date,
    }})) |th| {
        th.detach();
    } else |_| {
        g_update_in_progress.store(false, .release);
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    eu5.updater.cleanupOldBinary();

    var split_idx: usize = args.len;
    for (args[1..], 1..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--")) {
            split_idx = idx;
            break;
        }
    }
    const flags = args[1..split_idx];
    const game_command = if (split_idx + 1 < args.len) args[split_idx + 1 ..] else args[args.len..];

    var no_launch = false;
    var keep_open = false;
    var run_once = false;
    var launch_with_command = false;
    var generate_config = false;
    var check_update_only = false;
    var apply_update_now = false;
    var no_update = false;
    var no_tray = false;

    for (flags) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            _ = printf("eu5-rpc v%s\n", eu5.VERSION.ptr);
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            _ = printf(
                "Europa Universalis V Rich Presence for Discord (Zig Edition v%s, GPL-3.0)\n" ++
                    "Usage: eu5-rpc [OPTIONS] [-- <game command>]\n\n" ++
                    "Options:\n" ++
                    "  --no-launch                    Skip launching EU5 via Steam on startup\n" ++
                    "  --keep-open                    Keep running after EU5 closes\n" ++
                    "  --no-tray                      Run without the persistent system tray icon\n" ++
                    "  --no-update                    Skip automatic GitHub update check on startup\n" ++
                    "  --check-update                 Check GitHub for a newer release (or Ruby migration) and exit\n" ++
                    "  --update                       Download and install the latest Zig release from GitHub\n" ++
                    "  --once                         Probe EU5 telemetry once, print status, and exit\n" ++
                    "  --launch-with-command -- <cmd> Launch custom command (for Steam %%command%%)\n" ++
                    "  --generate-config              Write default config.toml and exit\n" ++
                    "  --install                      Install desktop entry & binary to ~/.local (Linux)\n" ++
                    "  --uninstall                    Remove installed desktop entry & binary (Linux)\n" ++
                    "  -v, --version                  Show version\n" ++
                    "  -h, --help                     Show this help message\n",
                eu5.VERSION.ptr,
            );
            return;
        } else if (std.mem.eql(u8, arg, "--install")) {
            installLinux();
            return;
        } else if (std.mem.eql(u8, arg, "--uninstall")) {
            uninstallLinux();
            return;
        } else if (std.mem.eql(u8, arg, "--generate-config")) {
            generate_config = true;
        } else if (std.mem.eql(u8, arg, "--no-launch")) {
            no_launch = true;
        } else if (std.mem.eql(u8, arg, "--keep-open")) {
            keep_open = true;
        } else if (std.mem.eql(u8, arg, "--no-tray")) {
            no_tray = true;
        } else if (std.mem.eql(u8, arg, "--no-update")) {
            no_update = true;
        } else if (std.mem.eql(u8, arg, "--check-update")) {
            check_update_only = true;
        } else if (std.mem.eql(u8, arg, "--update")) {
            apply_update_now = true;
        } else if (std.mem.eql(u8, arg, "--once")) {
            run_once = true;
            no_launch = true;
        } else if (std.mem.eql(u8, arg, "--launch-with-command")) {
            launch_with_command = true;
        }
    }

    if (check_update_only or apply_update_now) {
        const res = eu5.updater.checkForUpdate(init.gpa, init.io);
        switch (res.status) {
            .up_to_date => {
                _ = printf("EU5 RPC v%s is up to date.\n", eu5.VERSION.ptr);
            },
            .update_available, .migrating_from_ruby => {
                const rel = res.release.?;
                var tag_z: [65]u8 = undefined;
                @memcpy(tag_z[0..rel.tag_len], rel.tagName());
                tag_z[rel.tag_len] = 0;
                if (res.legacy_ruby_detected) {
                    _ = printf("Legacy Ruby install detected. Latest Zig release: %s (%s)\n", &tag_z, eu5.GITHUB_RELEASES_LATEST_URL);
                } else {
                    _ = printf("Update available: %s -> %s (%s)\n", eu5.VERSION.ptr, &tag_z, eu5.GITHUB_RELEASES_LATEST_URL);
                }
                if (apply_update_now) {
                    if (eu5.updater.applyUpdate(init.gpa, init.io, &rel)) {
                        _ = printf("Updated to %s successfully.\n", &tag_z);
                    } else {
                        _ = printf("Automatic update failed. Download manually from %s\n", eu5.GITHUB_RELEASES_LATEST_URL);
                    }
                }
            },
            else => {
                _ = printf("Failed to check GitHub Releases (%s).\n", eu5.GITHUB_RELEASES_LATEST_URL);
            },
        }
        return;
    }

    var data_dir_buf: [512]u8 = undefined;
    const data_dir = eu5.config.resolveDataDir(&data_dir_buf);
    var cfg_path_buf: [560]u8 = undefined;
    const cfg_path = eu5.config.configPath(data_dir, &cfg_path_buf) catch "config.toml";

    if (generate_config) {
        if (eu5.config.writeDefaultConfig(cfg_path.ptr)) {
            _ = printf("Wrote default config.toml to %s\n", cfg_path.ptr);
        } else {
            _ = printf("Failed to write config.toml to %s\n", cfg_path.ptr);
        }
        return;
    }

    const cfg = eu5.config.loadOrCreate(arena, cfg_path.ptr);

    var game_install_buf: [600]u8 = undefined;
    var lookup_loaded = false;
    var lookup = eu5.country_lookup.CountryLookup.init(std.heap.page_allocator);
    defer lookup.deinit();
    if (eu5.eu5_files.findEu5GameInstallDir(&game_install_buf)) |gd| {
        lookup_loaded = (lookup.loadFromGameDir(gd) > 0);
    }

    if (run_once) {
        var state = eu5.game_state.GameState{};
        var user_dir_buf: [768]u8 = undefined;
        const user_dir = eu5.eu5_files.findEu5UserDataDir(cfg.general.userDataFolderOpt(), &user_dir_buf);

        var watcher = eu5.log_watcher.LogWatcher.init(user_dir, cfg.general.userDataFolderOpt());
        var steam_rp = eu5.steam_rp.SteamRichPresence{};
        defer steam_rp.disconnect();

        if (eu5.process.eu5Running()) {
            state.enterLoading();
            var steam_has_country = false;
            if (steam_rp.poll()) |rp_upd| {
                steam_has_country = (rp_upd.country() != null);
                state.applySteamUpdate(&rp_upd);
            }
            watcher.step(std.heap.page_allocator, &state, &lookup, steam_has_country);
        } else if (user_dir) |ud| {
            var ver_buf: [64]u8 = undefined;
            if (eu5.save_inspector.readContinueGameField(ud, "rawGameVersion", &ver_buf)) |v| {
                state.setGameVersion(v);
            }
        }

        var d_buf: [256]u8 = undefined;
        var s_buf: [256]u8 = undefined;
        const pres = state.formatPresence(&cfg.presence, &d_buf, &s_buf);
        var d_z: [257]u8 = undefined;
        var s_z: [257]u8 = undefined;
        @memcpy(d_z[0..pres.details.len], pres.details);
        d_z[pres.details.len] = 0;
        const st = pres.state orelse "";
        @memcpy(s_z[0..st.len], st);
        s_z[st.len] = 0;
        _ = printf("Details: %s\nState:   %s\n", &d_z, &s_z);
        return;
    }

    var log = eu5.logger.Logger{};
    log.init(data_dir);
    defer log.close();
    log.info("[config] Loaded from {s}", .{cfg_path});

    if (!acquireSingleInstance()) {
        if (launch_with_command and game_command.len > 0) {
            eu5.eu5_files.spawnCustomCommand(arena, game_command, true);
        } else if (!no_launch and cfg.general.launch_game_on_start and !eu5.process.eu5Running()) {
            eu5.eu5_files.launchEu5ViaSteam();
        } else {
            log.info("[eu5-rpc] Another instance is already running. Exiting.", .{});
        }
        return;
    }

    if (builtin.os.tag != .windows) {
        _ = posix.signal(posix.SIGINT, @intFromPtr(&handleStopSignal));
        _ = posix.signal(posix.SIGTERM, @intFromPtr(&handleStopSignal));
        _ = posix.signal(posix.SIGPIPE, posix.SIG_IGN);
    }

    // Start persistent system tray icon
    var tray = eu5.tray.Tray.init();
    if (!no_tray) {
        tray.start();
    }
    defer tray.stopAndJoin();

    // Non-blocking startup auto-update & legacy Ruby -> Zig migration check
    if (cfg.general.auto_update and !no_update) {
        triggerBackgroundUpdate(init.gpa, init.io, &tray, false);
    }

    if (launch_with_command and game_command.len > 0) {
        eu5.eu5_files.spawnCustomCommand(arena, game_command, false);
    } else if (!no_launch and cfg.general.launch_game_on_start and !eu5.process.eu5Running()) {
        log.info("[launcher] Launching Europa Universalis V via Steam (AppID {s})...", .{eu5.EU5_STEAM_APP_ID});
        eu5.eu5_files.launchEu5ViaSteam();
    }

    var user_dir_buf: [768]u8 = undefined;
    const user_dir = eu5.eu5_files.findEu5UserDataDir(cfg.general.userDataFolderOpt(), &user_dir_buf);
    if (user_dir) |ud| {
        log.info("[eu5] Detected Paradox user data folder: {s}", .{ud});
    } else {
        log.warn("[eu5] Paradox EU5 user data folder not found yet. Waiting for launch...", .{});
    }

    var state = eu5.game_state.GameState{};
    var watcher = eu5.log_watcher.LogWatcher.init(user_dir, cfg.general.userDataFolderOpt());
    watcher.seedInitialOffsets();

    var discord = eu5.discord_ipc.DiscordIpc{};
    defer discord.close();
    var steam_rp = eu5.steam_rp.SteamRichPresence{};
    defer steam_rp.disconnect();

    const app_id = cfg.general.effectiveAppId();
    const poll_ms: u32 = @max(cfg.general.poll_interval_ms, 250);
    const discord_interval_s: i64 = @max(@as(i64, cfg.general.discord_update_interval_s), 1);
    const session_start: i64 = time(null);

    var game_was_running = false;
    var last_discord_attempt: i64 = 0;
    var last_discord_push: i64 = 0;
    var last_phase: eu5.game_state.GamePhase = .not_running;
    var last_details_buf: [256]u8 = undefined;
    var last_details_len: usize = 0;
    var last_state_buf: [256]u8 = undefined;
    var last_state_len: usize = 0;
    var has_pushed = false;

    while (!g_stop.load(.acquire)) {
        // Handle persistent tray actions immediately
        switch (tray.pollAction()) {
            .none => {},
            .launch_game => {
                if (!eu5.process.eu5Running()) {
                    log.info("[tray] Launching Europa Universalis V via Steam...", .{});
                    eu5.eu5_files.launchEu5ViaSteam();
                }
            },
            .check_update => {
                log.info("[tray] Checking GitHub Releases for updates...", .{});
                triggerBackgroundUpdate(init.gpa, init.io, &tray, true);
            },
            .open_config => {
                eu5.tray.openConfigFolder(data_dir);
            },
            .quit_all => {
                log.info("[tray] Quit selected - closing Europa Universalis V and EU5 RPC...", .{});
                steam_rp.disconnect();
                if (discord.connected) discord.clearActivity();
                eu5.process.closeEu5();
                return;
            },
        }

        const now = time(null);
        const running = eu5.process.eu5Running();

        if (running) {
            if (!game_was_running) {
                game_was_running = true;
                log.info("[process] Europa Universalis V detected (eu5.exe)", .{});
                if (state.phase == .not_running) {
                    state.enterLoading();
                }
                if (watcher.refreshUserDataDir()) {
                    if (watcher.userDataDir()) |ud| {
                        log.info("[eu5] Switched to active Paradox user data folder: {s}", .{ud});
                    }
                }
                if (!lookup_loaded) {
                    if (eu5.eu5_files.findEu5GameInstallDir(&game_install_buf)) |gd| {
                        lookup_loaded = (lookup.loadFromGameDir(gd) > 0);
                    }
                }
            }

            var steam_has_country = false;
            if (steam_rp.poll()) |rp_upd| {
                steam_has_country = (rp_upd.country() != null);
                state.applySteamUpdate(&rp_upd);
            }

            watcher.step(std.heap.page_allocator, &state, &lookup, steam_has_country);
        } else if (game_was_running) {
            log.info("[process] Europa Universalis V exited - clearing Discord presence", .{});
            steam_rp.disconnect();
            state.reset();
            discord.clearActivity();
            has_pushed = false;
            game_was_running = false;
            if (cfg.general.exit_when_game_closes and !keep_open) return;
        }

        // Keep tray tooltip & status header synced with current game state
        {
            var td_buf: [256]u8 = undefined;
            var ts_buf: [256]u8 = undefined;
            const tpres = state.formatPresence(&cfg.presence, &td_buf, &ts_buf);
            tray.updateStatus(if (running) tpres.details else "Waiting for Europa Universalis V", running);
        }

        if (!discord.connected and (last_discord_attempt == 0 or now - last_discord_attempt >= 10)) {
            last_discord_attempt = now;
            if (discord.connect(app_id)) {
                log.info("[discord] Connected!", .{});
                has_pushed = false;
            }
        }

        if (discord.connected and running and (!has_pushed or now - last_discord_push >= discord_interval_s)) {
            var d_buf: [256]u8 = undefined;
            var s_buf: [256]u8 = undefined;
            const pres = state.formatPresence(&cfg.presence, &d_buf, &s_buf);
            const s_slice = pres.state orelse "";

            const changed = !has_pushed or
                state.phase != last_phase or
                !std.mem.eql(u8, pres.details, last_details_buf[0..last_details_len]) or
                !std.mem.eql(u8, s_slice, last_state_buf[0..last_state_len]);

            if (changed) {
                const ts: ?i64 = if (cfg.presence.show_session_timer) session_start else null;
                if (discord.setActivity(pres.details, pres.state, ts, &cfg.images)) {
                    log.info("[rpc] phase={s} details=\"{s}\" state=\"{s}\"", .{
                        state.phase.name(),
                        pres.details,
                        if (s_slice.len > 0) s_slice else "none",
                    });
                    last_phase = state.phase;
                    @memcpy(last_details_buf[0..pres.details.len], pres.details);
                    last_details_len = pres.details.len;
                    @memcpy(last_state_buf[0..s_slice.len], s_slice);
                    last_state_len = s_slice.len;
                    has_pushed = true;
                    last_discord_push = now;
                } else {
                    log.warn("[rpc] setActivity failed; will reconnect", .{});
                }
            }
        }

        sleepMs(poll_ms, &tray);
    }

    if (discord.connected) {
        discord.clearActivity();
    }
}
