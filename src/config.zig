// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml.zig");
const eu5_files = @import("eu5_files.zig");
const root = @import("root.zig");

const win = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
} else struct {};

pub const CURRENT_CONFIG_VERSION: i64 = 1;

pub const DEFAULT_TOML =
    \\[general]
    \\# Leave blank to automatically link with Discord's built-in Europa Universalis V application.
    \\discord_app_id = ""
    \\launch_game_on_start = true
    \\exit_when_game_closes = false
    \\auto_update = true
    \\poll_interval_ms = 1000
    \\discord_update_interval_s = 5
    \\# Override Paradox user data folder if auto-detection fails.
    \\# Example: Documents\Paradox Interactive\Europa Universalis V
    \\user_data_folder = ""
    \\config_version = 1
    \\
    \\[presence]
    \\show_game_version = true
    \\show_historical_age = true
    \\show_live_events = true
    \\show_session_timer = true
    \\
    \\[presence.status]
    \\game_not_running = "Not Running"
    \\loading = "Loading Europa Universalis V..."
    \\in_main_menu = "Browsing the Main Menu"
    \\# Supports {country}, {tag}, {year}, {date}, {age}
    \\in_game_with_country = "Playing as {country} ({year})"
    \\in_game_unknown_country = "In Campaign ({year})"
    \\observing = "Observing the World ({year})"
    \\
    \\[images]
    \\# Direct HTTPS image URL or Discord Art Asset key.
    \\large_image = "https://raw.githubusercontent.com/buntatoes/eu5-rpc/main/assets/icon.png"
    \\large_image_tooltip = "Europa Universalis V"
    \\small_image = ""
    \\small_image_tooltip = "EU5 RPC"
    \\
;

pub fn FixedStr(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn from(s: []const u8) Self {
            var res = Self{};
            res.set(s);
            return res;
        }

        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, cap);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }
    };
}

pub const GeneralConfig = struct {
    discord_app_id: FixedStr(64) = .{},
    launch_game_on_start: bool = true,
    exit_when_game_closes: bool = false,
    auto_update: bool = true,
    poll_interval_ms: u32 = 1000,
    discord_update_interval_s: u32 = 5,
    user_data_folder: FixedStr(512) = .{},
    config_version: i64 = CURRENT_CONFIG_VERSION,

    pub fn effectiveAppId(self: *const GeneralConfig) []const u8 {
        const s = std.mem.trim(u8, self.discord_app_id.slice(), " \t\r\n");
        return if (s.len > 0) s else root.DEFAULT_DISCORD_APP_ID;
    }

    pub fn userDataFolderOpt(self: *const GeneralConfig) ?[]const u8 {
        const s = std.mem.trim(u8, self.user_data_folder.slice(), " \t\r\n");
        return if (s.len > 0) s else null;
    }
};

pub const StatusStrings = struct {
    game_not_running: FixedStr(128) = FixedStr(128).from("Not Running"),
    loading: FixedStr(128) = FixedStr(128).from("Loading Europa Universalis V..."),
    in_main_menu: FixedStr(128) = FixedStr(128).from("Browsing the Main Menu"),
    in_game_with_country: FixedStr(128) = FixedStr(128).from("Playing as {country} ({year})"),
    in_game_unknown_country: FixedStr(128) = FixedStr(128).from("In Campaign ({year})"),
    observing: FixedStr(128) = FixedStr(128).from("Observing the World ({year})"),
};

pub const PresenceConfig = struct {
    show_game_version: bool = true,
    show_historical_age: bool = true,
    show_live_events: bool = true,
    show_session_timer: bool = true,
    status: StatusStrings = .{},
};

pub const ImagesConfig = struct {
    large_image: FixedStr(256) = FixedStr(256).from(root.DEFAULT_LARGE_IMAGE_URL),
    large_image_tooltip: FixedStr(128) = FixedStr(128).from("Europa Universalis V"),
    small_image: FixedStr(256) = .{},
    small_image_tooltip: FixedStr(128) = FixedStr(128).from("EU5 RPC"),
};

pub const Config = struct {
    general: GeneralConfig = .{},
    presence: PresenceConfig = .{},
    images: ImagesConfig = .{},

    pub fn fromToml(doc: *const toml.Document) Config {
        var cfg = Config{};

        if (doc.getString("general", "discord_app_id")) |v| {
            cfg.general.discord_app_id.set(std.mem.trim(u8, v, " \t\r\n"));
        }
        if (doc.getBool("general", "launch_game_on_start")) |v| cfg.general.launch_game_on_start = v;
        if (doc.getBool("general", "exit_when_game_closes")) |v| cfg.general.exit_when_game_closes = v;
        if (doc.getBool("general", "auto_update")) |v| cfg.general.auto_update = v;
        if (doc.getInt("general", "poll_interval_ms")) |v| {
            if (v > 0 and v <= 60_000) cfg.general.poll_interval_ms = @intCast(v);
        }
        if (doc.getInt("general", "discord_update_interval_s")) |v| {
            if (v > 0 and v <= 3600) cfg.general.discord_update_interval_s = @intCast(v);
        }
        if (doc.getString("general", "user_data_folder")) |v| {
            cfg.general.user_data_folder.set(std.mem.trim(u8, v, " \t\r\n"));
        }
        if (doc.getInt("general", "config_version")) |v| cfg.general.config_version = v;

        if (doc.getBool("presence", "show_game_version")) |v| cfg.presence.show_game_version = v;
        if (doc.getBool("presence", "show_historical_age")) |v| cfg.presence.show_historical_age = v;
        if (doc.getBool("presence", "show_live_events")) |v| cfg.presence.show_live_events = v;
        if (doc.getBool("presence", "show_session_timer")) |v| cfg.presence.show_session_timer = v;

        if (doc.getString("presence.status", "game_not_running")) |v| cfg.presence.status.game_not_running.set(v);
        if (doc.getString("presence.status", "loading")) |v| cfg.presence.status.loading.set(v);
        if (doc.getString("presence.status", "in_main_menu")) |v| cfg.presence.status.in_main_menu.set(v);
        if (doc.getString("presence.status", "in_game_with_country")) |v| cfg.presence.status.in_game_with_country.set(v);
        if (doc.getString("presence.status", "in_game_unknown_country")) |v| cfg.presence.status.in_game_unknown_country.set(v);
        if (doc.getString("presence.status", "observing")) |v| cfg.presence.status.observing.set(v);

        if (doc.getString("images", "large_image")) |v| cfg.images.large_image.set(v);
        if (doc.getString("images", "large_image_tooltip")) |v| cfg.images.large_image_tooltip.set(v);
        if (doc.getString("images", "small_image")) |v| cfg.images.small_image.set(v);
        if (doc.getString("images", "small_image_tooltip")) |v| cfg.images.small_image_tooltip.set(v);

        return cfg;
    }
};

pub const TemplateVars = struct {
    country: []const u8 = "",
    tag: []const u8 = "",
    year: []const u8 = "",
    date: []const u8 = "",
    age: []const u8 = "",
};

/// Substitutes `{country}`, `{tag}`, `{year}`, `{date}`, and `{age}` in `template`.
pub fn applyVars(out: []u8, template: []const u8, vars: TemplateVars) []const u8 {
    var pos: usize = 0;
    var i: usize = 0;

    while (i < template.len and pos < out.len) {
        if (template[i] == '{') {
            const rest = template[i..];
            const replacement: ?struct { val: []const u8, tok_len: usize } = if (std.mem.startsWith(u8, rest, "{country}"))
                .{ .val = vars.country, .tok_len = "{country}".len }
            else if (std.mem.startsWith(u8, rest, "{tag}"))
                .{ .val = vars.tag, .tok_len = "{tag}".len }
            else if (std.mem.startsWith(u8, rest, "{year}"))
                .{ .val = vars.year, .tok_len = "{year}".len }
            else if (std.mem.startsWith(u8, rest, "{date}"))
                .{ .val = vars.date, .tok_len = "{date}".len }
            else if (std.mem.startsWith(u8, rest, "{age}"))
                .{ .val = vars.age, .tok_len = "{age}".len }
            else
                null;

            if (replacement) |rep| {
                const copy_n = @min(rep.val.len, out.len - pos);
                @memcpy(out[pos .. pos + copy_n], rep.val[0..copy_n]);
                pos += copy_n;
                i += rep.tok_len;
                continue;
            }
        }
        out[pos] = template[i];
        pos += 1;
        i += 1;
    }
    return out[0..pos];
}

pub fn ensureDirRecursive(path: []const u8) void {
    eu5_files.ensureDirRecursive(path);
}

fn dirWritableWindows(dir: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    var probe_buf: [640]u8 = undefined;
    const probe = root.bufPrintZ(&probe_buf, "{s}\\.eu5_rpc_write_test_{d}", .{ dir, win.GetCurrentProcessId() }) catch return false;
    if (!eu5_files.writeFileAll(probe.ptr, "")) return false;
    eu5_files.deleteFileUtf8(probe.ptr);
    return true;
}

/// Resolves the per-user configuration/log data directory and creates it if needed.
/// Windows: executable directory if writable (portable / `%LOCALAPPDATA%\EU5-RPC`), else `%LOCALAPPDATA%\EU5-RPC` (full Unicode support).
/// Linux:   `$XDG_CONFIG_HOME/eu5-rpc` or `$HOME/.config/eu5-rpc`.
pub fn resolveDataDir(out_buf: []u8) []const u8 {
    if (builtin.os.tag == .windows) {
        var mod_dir_buf: [512]u8 = undefined;
        if (eu5_files.getModuleDirUtf8(&mod_dir_buf)) |dir| {
            if (dirWritableWindows(dir)) {
                if (root.bufPrintZ(out_buf, "{s}", .{dir})) |res| return res else |_| {}
            }
        }
        var env_buf: [512]u8 = undefined;
        if (eu5_files.getEnvUtf8("LOCALAPPDATA", &env_buf)) |p| {
            if (root.bufPrintZ(out_buf, "{s}\\EU5-RPC", .{p})) |res| {
                ensureDirRecursive(res);
                return res;
            } else |_| {}
        }
        if (eu5_files.getEnvUtf8("USERPROFILE", &env_buf)) |p| {
            if (root.bufPrintZ(out_buf, "{s}\\AppData\\Local\\EU5-RPC", .{p})) |res| {
                ensureDirRecursive(res);
                return res;
            } else |_| {}
        }
        return ".";
    } else {
        var env_buf: [512]u8 = undefined;
        if (eu5_files.getEnvUtf8("XDG_CONFIG_HOME", &env_buf)) |p| {
            const base = std.mem.trimEnd(u8, p, "/");
            if (base.len > 0) {
                if (root.bufPrintZ(out_buf, "{s}/eu5-rpc", .{base})) |res| {
                    ensureDirRecursive(res);
                    return res;
                } else |_| {}
            }
        }
        if (eu5_files.getEnvUtf8("HOME", &env_buf)) |p| {
            const home = std.mem.trimEnd(u8, p, "/");
            if (home.len > 0) {
                if (root.bufPrintZ(out_buf, "{s}/.config/eu5-rpc", .{home})) |res| {
                    ensureDirRecursive(res);
                    return res;
                } else |_| {}
            }
        }
        return ".";
    }
}

pub fn configPath(base_dir: []const u8, out_buf: []u8) error{NoSpaceLeft}![:0]u8 {
    const sep = if (builtin.os.tag == .windows) "\\" else "/";
    return root.bufPrintZ(out_buf, "{s}{s}config.toml", .{ base_dir, sep });
}

pub fn writeDefaultConfig(path_z: [*:0]const u8) bool {
    return eu5_files.writeFileAll(path_z, DEFAULT_TOML);
}

pub fn loadOrCreate(alloc: std.mem.Allocator, path_z: [*:0]const u8) Config {
    if (!eu5_files.fileExists(path_z)) {
        _ = writeDefaultConfig(path_z);
        return Config{};
    }
    const raw = eu5_files.readFileAlloc(alloc, path_z, 512 * 1024) orelse return Config{};
    defer alloc.free(raw);

    var doc = toml.parse(alloc, raw) catch return Config{};
    defer doc.deinit();

    return Config.fromToml(&doc);
}

test "default TOML parses to expected EU5 RPC defaults" {
    var doc = try toml.parse(std.testing.allocator, DEFAULT_TOML);
    defer doc.deinit();

    const cfg = Config.fromToml(&doc);
    try std.testing.expectEqual(true, cfg.general.launch_game_on_start);
    try std.testing.expectEqual(false, cfg.general.exit_when_game_closes);
    try std.testing.expectEqual(true, cfg.general.auto_update);
    try std.testing.expectEqual(@as(u32, 1000), cfg.general.poll_interval_ms);
    try std.testing.expectEqual(@as(u32, 5), cfg.general.discord_update_interval_s);
    try std.testing.expectEqualStrings(root.DEFAULT_DISCORD_APP_ID, cfg.general.effectiveAppId());
    try std.testing.expectEqualStrings("Playing as {country} ({year})", cfg.presence.status.in_game_with_country.slice());
    try std.testing.expectEqualStrings(root.DEFAULT_LARGE_IMAGE_URL, cfg.images.large_image.slice());
}

test "template variable substitution replaces all supported tokens" {
    var buf: [256]u8 = undefined;
    const out = applyVars(&buf, "Playing as {country} [{tag}] in {year} ({date}) - {age}", .{
        .country = "France",
        .tag = "FRA",
        .year = "1453",
        .date = "1453.5.29",
        .age = "Age of Renaissance",
    });
    try std.testing.expectEqualStrings("Playing as France [FRA] in 1453 (1453.5.29) - Age of Renaissance", out);
}
