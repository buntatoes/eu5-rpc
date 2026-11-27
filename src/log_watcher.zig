// SPDX-License-Identifier: GPL-3.0-only
// Strictly read-only watcher for EU5's live log files (logs/debug.log, logs/game.log,
// logs/multiplayer.log) and newest save header. Never modifies game files or reads memory.
const std = @import("std");
const builtin = @import("builtin");
const gs = @import("game_state.zig");
const country_lookup_mod = @import("country_lookup.zig");
const save_inspector = @import("save_inspector.zig");
const eu5_files = @import("eu5_files.zig");
const proc = @import("process.zig");
const root = @import("root.zig");

extern "c" fn time(tloc: ?*i64) i64;

pub const RESYNC_BYTES: u64 = 2 * 1024 * 1024;

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isWordChar(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or isDigit(ch) or ch == '_';
}

fn isAlpha(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z');
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn parseVersionToken(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    const f_start = i;
    while (i < s.len and isDigit(s[i])) : (i += 1) {}
    if (i - f_start < 1 or i - f_start > 2 or i >= s.len or s[i] != '.') return null;
    i += 1;

    const s_start = i;
    while (i < s.len and isDigit(s[i])) : (i += 1) {}
    if (i - s_start < 1 or i - s_start > 2 or i >= s.len or s[i] != '.') return null;
    i += 1;

    const t_start = i;
    while (i < s.len and isDigit(s[i])) : (i += 1) {}
    if (i - t_start < 1 or i - t_start > 2) return null;

    if (i + 1 < s.len and s[i] == '.' and isDigit(s[i + 1])) {
        i += 1;
        while (i < s.len and isDigit(s[i])) : (i += 1) {}
    }

    return s[0..i];
}

pub fn processDebugLine(line: []const u8, state: *gs.GameState) void {
    // 1. Game version: "game version 1.4.7"
    if (indexOfIgnoreCase(line, "game version")) |idx| {
        const after = std.mem.trimStart(u8, line[idx + "game version".len ..], " \t");
        if (parseVersionToken(after)) |ver| {
            state.setGameVersion(ver);
        }
    }

    // 2. Transition: "Running Transition <From>-><To>"
    if (std.mem.indexOf(u8, line, "Running Transition")) |idx| {
        const after = std.mem.trimStart(u8, line[idx + "Running Transition".len ..], " \t");
        if (std.mem.indexOf(u8, after, "->")) |arrow| {
            const rhs = after[arrow + 2 ..];
            var end: usize = 0;
            while (end < rhs.len and isWordChar(rhs[end])) : (end += 1) {}
            const target = rhs[0..end];
            if (std.mem.eql(u8, target, "SplashScreen") or std.mem.eql(u8, target, "LoadingScreen")) {
                state.enterLoading();
            } else if (std.mem.eql(u8, target, "MainMenu")) {
                state.enterMainMenu();
            } else if (std.mem.eql(u8, target, "Game")) {
                state.enterGame();
            } else if (std.mem.eql(u8, target, "Empty")) {
                state.reset();
            }
        }
    }
}

fn parseBoolAfter(line: []const u8, marker: []const u8) ?bool {
    const idx = indexOfIgnoreCase(line, marker) orelse return null;
    const rest = std.mem.trimStart(u8, line[idx + marker.len ..], " \t");
    if (std.ascii.startsWithIgnoreCase(rest, "true")) return true;
    if (std.ascii.startsWithIgnoreCase(rest, "false")) return false;
    return null;
}

pub fn processMultiplayerLine(
    line: []const u8,
    state: *gs.GameState,
    lookup: ?*const country_lookup_mod.CountryLookup,
) void {
    if (parseBoolAfter(line, "Is Multiplayer:")) |b| {
        state.multiplayer = b;
        return;
    }
    if (parseBoolAfter(line, "Is Multiplayer Host:")) |b| {
        state.multiplayer_host = b;
        return;
    }
    if (parseBoolAfter(line, "_Player Is Observer:")) |b| {
        state.observer = b;
        return;
    }

    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "New Country:")) {
        const raw_tag = std.mem.trim(u8, trimmed["New Country:".len..], " \t");
        if (raw_tag.len > 0) {
            var all_word = true;
            for (raw_tag) |ch| {
                if (!isWordChar(ch)) {
                    all_word = false;
                    break;
                }
            }
            if (all_word) {
                if (std.ascii.eqlIgnoreCase(raw_tag, "No") or std.ascii.eqlIgnoreCase(raw_tag, "None")) {
                    state.clearCountry();
                } else {
                    var upper_buf: [32]u8 = undefined;
                    const n = @min(raw_tag.len, upper_buf.len);
                    for (raw_tag[0..n], 0..) |ch, i| upper_buf[i] = std.ascii.toUpper(ch);
                    const tag = upper_buf[0..n];
                    state.setCountryTag(tag);

                    var res_buf: [32]u8 = undefined;
                    const resolved = if (lookup) |lk|
                        lk.resolve(tag, &res_buf) orelse tag
                    else
                        country_lookup_mod.lookupFallbackTag(tag) orelse tag;
                    state.setCountryName(resolved);
                    state.clearActiveEvent();
                    if (state.phase != .in_game) state.enterGame();
                }
                return;
            }
        }
    }

    if (std.mem.indexOf(u8, line, "Destroying gamestate") != null) {
        state.clearActiveEvent();
    }
}

fn titleCaseUnderscores(src: []const u8, out_buf: []u8) []const u8 {
    var out_len: usize = 0;
    var at_word_start = true;
    for (src) |ch| {
        if (ch == '_' or ch == ' ' or ch == '\t') {
            if (out_len > 0 and out_buf[out_len - 1] != ' ' and out_len < out_buf.len) {
                out_buf[out_len] = ' ';
                out_len += 1;
            }
            at_word_start = true;
        } else {
            if (out_len < out_buf.len) {
                out_buf[out_len] = if (at_word_start) std.ascii.toUpper(ch) else std.ascii.toLower(ch);
                out_len += 1;
            }
            at_word_start = false;
        }
    }
    return std.mem.trimEnd(u8, out_buf[0..out_len], " ");
}

pub fn processGameLine(line: []const u8, state: *gs.GameState) void {
    const trimmed_line = std.mem.trimEnd(u8, line, "\r\n");

    // 1. NEW YEAR: 1454
    if (std.mem.indexOf(u8, trimmed_line, "NEW YEAR:")) |idx| {
        const after = std.mem.trimStart(u8, trimmed_line[idx + "NEW YEAR:".len ..], " \t");
        var end: usize = 0;
        while (end < after.len and isDigit(after[end])) : (end += 1) {}
        if (end >= 3 and end <= 4) {
            if (std.fmt.parseInt(u32, after[0..end], 10)) |y| {
                if (y >= 1337) {
                    state.year = y;
                    state.setDateStr(after[0..end]);
                }
            } else |_| {}
        }
        return;
    }

    // 2. SITUATION: Rise of the Turks starts on 1 May, 1337
    if (std.mem.indexOf(u8, trimmed_line, "SITUATION:")) |sit_idx| {
        if (indexOfIgnoreCase(trimmed_line[sit_idx..], " starts on ")) |rel| {
            const date_start = sit_idx + rel + " starts on ".len;
            const rest = trimmed_line[date_start..];
            var i: usize = 0;
            const d0 = i;
            while (i < rest.len and isDigit(rest[i])) : (i += 1) {}
            if (i - d0 >= 1 and i - d0 <= 2 and i < rest.len and rest[i] == ' ') {
                while (i < rest.len and rest[i] == ' ') : (i += 1) {}
                const m0 = i;
                while (i < rest.len and isAlpha(rest[i])) : (i += 1) {}
                if (i > m0 and i < rest.len and rest[i] == ',') {
                    i += 1;
                    while (i < rest.len and rest[i] == ' ') : (i += 1) {}
                    const y0 = i;
                    while (i < rest.len and isDigit(rest[i])) : (i += 1) {}
                    if (i - y0 >= 3 and i - y0 <= 4) {
                        if (std.fmt.parseInt(u32, rest[y0..i], 10)) |y| {
                            if (y >= 1337 and (state.year == null or y >= state.year.?)) {
                                state.year = y;
                                state.setDateStr(rest[0..i]);
                            }
                        } else |_| {}
                    }
                }
            }
            return;
        }
    }

    // 3. Country-specific live events (WAR, CIVIL WAR, EXPLORATION)
    if (state.countryName()) |country| {
        if (std.mem.indexOf(u8, trimmed_line, "CIVIL WAR:")) |cw_idx| {
            const rest = std.mem.trimStart(u8, trimmed_line[cw_idx + "CIVIL WAR:".len ..], " \t");
            if (std.mem.indexOf(u8, rest, " against ")) |ag_idx| {
                const target = std.mem.trim(u8, rest[ag_idx + " against ".len ..], " \t");
                if (std.ascii.eqlIgnoreCase(target, country)) {
                    state.setActiveEvent("In a Civil War");
                }
            }
        } else if (std.mem.indexOf(u8, trimmed_line, "WAR:")) |w_idx| {
            const rest = std.mem.trimStart(u8, trimmed_line[w_idx + "WAR:".len ..], " \t");
            if (std.mem.indexOf(u8, rest, " declared war on ")) |dec_idx| {
                const attacker = std.mem.trim(u8, rest[0..dec_idx], " \t");
                const defender = std.mem.trim(u8, rest[dec_idx + " declared war on ".len ..], " \t");
                var ev_buf: [192]u8 = undefined;
                if (std.ascii.eqlIgnoreCase(attacker, country)) {
                    if (std.fmt.bufPrint(&ev_buf, "At War with {s}", .{defender})) |ev| state.setActiveEvent(ev) else |_| {}
                } else if (std.ascii.eqlIgnoreCase(defender, country)) {
                    if (std.fmt.bufPrint(&ev_buf, "Defending vs. {s}", .{attacker})) |ev| state.setActiveEvent(ev) else |_| {}
                }
            }
        } else if (std.mem.indexOf(u8, trimmed_line, "EXPLORATION:")) |ex_idx| {
            const rest = std.mem.trimStart(u8, trimmed_line[ex_idx + "EXPLORATION:".len ..], " \t");
            if (std.mem.indexOf(u8, rest, " discovered ")) |disc_idx| {
                const explorer = std.mem.trim(u8, rest[0..disc_idx], " \t");
                const after_disc = rest[disc_idx + " discovered ".len ..];
                if (std.mem.indexOf(u8, after_disc, "L;")) |l_idx| {
                    const after_l = std.mem.trimStart(u8, after_disc[l_idx + 2 ..], " \t");
                    if (std.mem.indexOfScalar(u8, after_l, '!')) |bang| {
                        const area = std.mem.trim(u8, after_l[0..bang], " \t");
                        if (std.ascii.eqlIgnoreCase(explorer, country) and area.len > 0) {
                            var ev_buf: [192]u8 = undefined;
                            if (std.fmt.bufPrint(&ev_buf, "Explored {s}", .{area})) |ev| state.setActiveEvent(ev) else |_| {}
                        }
                    }
                }
            }
        }
    }

    // 4. DISASTER: succession_crisis starts|ends in FRA
    if (state.countryTag()) |tag| {
        if (std.mem.indexOf(u8, trimmed_line, "DISASTER:")) |d_idx| {
            const rest = std.mem.trimStart(u8, trimmed_line[d_idx + "DISASTER:".len ..], " \t");
            var it = std.mem.tokenizeAny(u8, rest, " \t");
            const raw_name = it.next() orelse return;
            const action = it.next() orelse return;
            const in_kw = it.next() orelse return;
            const raw_affected = it.next() orelse return;
            if (!std.ascii.eqlIgnoreCase(in_kw, "in")) return;

            var tag_end: usize = 0;
            while (tag_end < raw_affected.len and isWordChar(raw_affected[tag_end])) : (tag_end += 1) {}
            const affected = raw_affected[0..tag_end];
            if (std.ascii.eqlIgnoreCase(affected, tag)) {
                if (std.ascii.eqlIgnoreCase(action, "starts")) {
                    var nice_buf: [128]u8 = undefined;
                    const nice = titleCaseUnderscores(raw_name, &nice_buf);
                    var ev_buf: [192]u8 = undefined;
                    if (std.fmt.bufPrint(&ev_buf, "Disaster: {s}", .{nice})) |ev| state.setActiveEvent(ev) else |_| {}
                } else if (std.ascii.eqlIgnoreCase(action, "ends")) {
                    state.clearActiveEvent();
                }
            }
        }
    }
}

pub const LogWatcher = struct {
    user_data_buf: [768]u8 = undefined,
    user_data_len: usize = 0,
    configured_dir_buf: [512]u8 = undefined,
    configured_dir_len: usize = 0,

    debug_offset: ?u64 = null,
    mp_offset: ?u64 = null,
    game_offset: ?u64 = null,

    last_save_path_buf: [768]u8 = undefined,
    last_save_path_len: usize = 0,
    last_save_mtime: ?i64 = null,
    last_cont_mtime: ?i64 = null,
    has_save_key: bool = false,

    session_started_at: i64 = 0,

    pub fn init(user_data_dir: ?[]const u8, configured_dir: ?[]const u8) LogWatcher {
        var lw = LogWatcher{
            .session_started_at = time(null),
        };
        if (user_data_dir) |d| lw.setUserDataDir(d);
        if (configured_dir) |c| {
            const n = @min(c.len, lw.configured_dir_buf.len);
            @memcpy(lw.configured_dir_buf[0..n], c[0..n]);
            lw.configured_dir_len = n;
        }
        return lw;
    }

    pub fn userDataDir(self: *const LogWatcher) ?[]const u8 {
        return if (self.user_data_len > 0) self.user_data_buf[0..self.user_data_len] else null;
    }

    fn configuredDir(self: *const LogWatcher) ?[]const u8 {
        return if (self.configured_dir_len > 0) self.configured_dir_buf[0..self.configured_dir_len] else null;
    }

    fn setUserDataDir(self: *LogWatcher, dir: []const u8) void {
        const n = @min(dir.len, self.user_data_buf.len);
        @memcpy(self.user_data_buf[0..n], dir[0..n]);
        self.user_data_len = n;
    }

    /// If EU5 is not already running at startup, skip stale log contents written by previous sessions.
    pub fn seedInitialOffsets(self: *LogWatcher) void {
        if (proc.eu5Running()) return;
        const dir = self.userDataDir() orelse return;
        const sep = if (builtin.os.tag == .windows) "\\" else "/";

        const targets = [_]struct { name: []const u8, slot: *?u64 }{
            .{ .name = "debug.log", .slot = &self.debug_offset },
            .{ .name = "multiplayer.log", .slot = &self.mp_offset },
            .{ .name = "game.log", .slot = &self.game_offset },
        };
        var path_buf: [840]u8 = undefined;
        for (targets) |t| {
            const p = root.bufPrintZ(&path_buf, "{s}{s}logs{s}{s}", .{ dir, sep, sep, t.name }) catch continue;
            if (eu5_files.fileMtime(p.ptr)) |mt| {
                if (mt < self.session_started_at - 3) {
                    t.slot.* = eu5_files.fileSize(p.ptr) orelse 0;
                }
            }
        }
    }

    /// Re-evaluates all candidate Paradox user data folders (Native, Proton, Wine, Windows) and
    /// switches if a more recently active directory is found (e.g. switching between Native and Proton).
    pub fn refreshUserDataDir(self: *LogWatcher) bool {
        var det_buf: [768]u8 = undefined;
        const detected = eu5_files.findEu5UserDataDir(self.configuredDir(), &det_buf) orelse return false;
        const cur = self.userDataDir() orelse "";
        if (std.mem.eql(u8, detected, cur)) return false;

        self.setUserDataDir(detected);
        self.debug_offset = null;
        self.mp_offset = null;
        self.game_offset = null;
        self.has_save_key = false;
        return true;
    }

    /// Switches to a newly created/detected Paradox user data directory if `<dir>/logs` does not yet exist.
    pub fn ensureUserDataDir(self: *LogWatcher) bool {
        const sep = if (builtin.os.tag == .windows) "\\" else "/";
        if (self.userDataDir()) |cur| {
            var logs_buf: [840]u8 = undefined;
            if (root.bufPrintZ(&logs_buf, "{s}{s}logs", .{ cur, sep })) |lp| {
                if (eu5_files.dirExists(lp.ptr)) return false;
            } else |_| {}
        }
        return self.refreshUserDataDir();
    }

    pub fn step(
        self: *LogWatcher,
        alloc: std.mem.Allocator,
        state: *gs.GameState,
        lookup: ?*const country_lookup_mod.CountryLookup,
        skip_country_from_saves: bool,
    ) void {
        _ = self.ensureUserDataDir();
        const dir = self.userDataDir() orelse return;
        const sep = if (builtin.os.tag == .windows) "\\" else "/";

        var path_buf: [840]u8 = undefined;
        if (root.bufPrintZ(&path_buf, "{s}{s}logs{s}debug.log", .{ dir, sep, sep })) |p| {
            tailLogFile(alloc, p.ptr, &self.debug_offset, state, lookup, .debug);
        } else |_| {}
        if (root.bufPrintZ(&path_buf, "{s}{s}logs{s}multiplayer.log", .{ dir, sep, sep })) |p| {
            tailLogFile(alloc, p.ptr, &self.mp_offset, state, lookup, .multiplayer);
        } else |_| {}
        if (root.bufPrintZ(&path_buf, "{s}{s}logs{s}game.log", .{ dir, sep, sep })) |p| {
            tailLogFile(alloc, p.ptr, &self.game_offset, state, lookup, .game);
        } else |_| {}

        self.refreshSaveMetadata(state, lookup, skip_country_from_saves);
    }

    pub fn refreshSaveMetadata(
        self: *LogWatcher,
        state: *gs.GameState,
        lookup: ?*const country_lookup_mod.CountryLookup,
        skip_country: bool,
    ) void {
        const dir = self.userDataDir() orelse return;
        const sep = if (builtin.os.tag == .windows) "\\" else "/";

        // Always allow continue_game.json to populate game_version if not yet known
        if (state.gameVersion() == null) {
            var ver_buf: [64]u8 = undefined;
            if (save_inspector.readContinueGameField(dir, "rawGameVersion", &ver_buf)) |v| {
                state.setGameVersion(v);
            }
        }

        if (skip_country) return;

        var saves_dir_buf: [840]u8 = undefined;
        const saves_dir = root.bufPrintZ(&saves_dir_buf, "{s}{s}save games", .{ dir, sep }) catch return;
        var newest_buf: [840]u8 = undefined;
        const newest_opt = save_inspector.findNewestSave(saves_dir, &newest_buf);
        const save_mtime: ?i64 = if (newest_opt) |ns| ns.mtime else null;

        var cont_buf: [840]u8 = undefined;
        const cont_mtime: ?i64 = if (root.bufPrintZ(&cont_buf, "{s}{s}continue_game.json", .{ dir, sep })) |cp|
            eu5_files.fileMtime(cp.ptr)
        else |_|
            null;

        const active_mtime: ?i64 = blk: {
            if (save_mtime != null and cont_mtime != null) break :blk @max(save_mtime.?, cont_mtime.?);
            break :blk save_mtime orelse cont_mtime;
        };

        // Only read saves written/updated during the CURRENT session so old saves never overwrite live state
        if (active_mtime == null or active_mtime.? < self.session_started_at - 5) return;

        const newest_path = if (newest_opt) |ns| ns.path else "";
        if (self.has_save_key and
            std.mem.eql(u8, self.last_save_path_buf[0..self.last_save_path_len], newest_path) and
            self.last_save_mtime == save_mtime and
            self.last_cont_mtime == cont_mtime)
        {
            return;
        }

        const meta = save_inspector.inspectUserDataDir(dir) orelse return;

        const pn = @min(newest_path.len, self.last_save_path_buf.len);
        @memcpy(self.last_save_path_buf[0..pn], newest_path[0..pn]);
        self.last_save_path_len = pn;
        self.last_save_mtime = save_mtime;
        self.last_cont_mtime = cont_mtime;
        self.has_save_key = true;

        if (meta.countryTag()) |tag| state.setCountryTag(tag);
        if (meta.countryName()) |cname| {
            state.setCountryName(cname);
        } else if (state.countryTag()) |tag| {
            var res_buf: [32]u8 = undefined;
            const resolved = if (lookup) |lk|
                lk.resolve(tag, &res_buf) orelse tag
            else
                country_lookup_mod.lookupFallbackTag(tag) orelse tag;
            state.setCountryName(resolved);
        }

        if (meta.year) |my| {
            if (state.year == null or my >= state.year.?) {
                state.year = my;
                if (meta.dateStr()) |ds| state.setDateStr(ds);
            }
        }
        if (meta.gameVersion()) |v| state.setGameVersion(v);
    }
};

const LogKind = enum { debug, multiplayer, game };

fn tailLogFile(
    alloc: std.mem.Allocator,
    path_z: [*:0]const u8,
    offset_slot: *?u64,
    state: *gs.GameState,
    lookup: ?*const country_lookup_mod.CountryLookup,
    kind: LogKind,
) void {
    const size = eu5_files.fileSize(path_z) orelse return;

    var start: u64 = 0;
    var skip_partial = false;

    if (offset_slot.*) |prev| {
        if (size == prev) return;
        if (size < prev) {
            start = 0;
            skip_partial = false;
        } else {
            start = prev;
            if (size - start > RESYNC_BYTES) {
                start = size - RESYNC_BYTES;
                skip_partial = true;
            }
        }
    } else {
        if (size > RESYNC_BYTES) {
            start = size - RESYNC_BYTES;
            skip_partial = true;
        } else {
            start = 0;
            skip_partial = false;
        }
    }

    const to_read_u64 = size - start;
    if (to_read_u64 == 0) {
        offset_slot.* = size;
        return;
    }
    const to_read: usize = @intCast(@min(to_read_u64, RESYNC_BYTES));

    const buf = alloc.alloc(u8, to_read) catch return;
    defer alloc.free(buf);

    const got = eu5_files.readFileRange(path_z, start, buf) orelse return;
    offset_slot.* = start + got;
    if (got == 0) return;

    var it = std.mem.splitScalar(u8, buf[0..got], '\n');
    var first = true;
    while (it.next()) |raw_line| {
        if (first and skip_partial) {
            first = false;
            continue;
        }
        first = false;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        switch (kind) {
            .debug => processDebugLine(line, state),
            .multiplayer => processMultiplayerLine(line, state, lookup),
            .game => processGameLine(line, state),
        }
    }
}

test "processes debug, multiplayer, and game log transitions and live events" {
    const cfg_mod = @import("config.zig");
    var state = gs.GameState{};
    const cfg = cfg_mod.Config{};

    processDebugLine("[14:55:33][pdx_transition_task.cpp:138]: Running Transition Empty->SplashScreen", &state);
    try std.testing.expectEqual(gs.GamePhase.loading, state.phase);

    processDebugLine("[14:55:35][dlc_reloadable.cpp:390]: Mod Sample version 1.4.* successfully matched game version 1.4.7.", &state);
    try std.testing.expectEqualStrings("1.4.7", state.gameVersion().?);

    processDebugLine("[14:55:38][pdx_transition_task.cpp:138]: Running Transition LoadingScreen->MainMenu", &state);
    try std.testing.expectEqual(gs.GamePhase.main_menu, state.phase);

    processDebugLine("[14:55:48][pdx_transition_task.cpp:138]: Running Transition MainMenu->Game", &state);
    try std.testing.expectEqual(gs.GamePhase.in_game, state.phase);

    state.setCountryName("France");
    state.setCountryTag("FRA");
    state.year = 1453;

    processMultiplayerLine("Is Multiplayer: true", &state, null);
    processMultiplayerLine("Is Multiplayer Host: true", &state, null);
    try std.testing.expectEqualStrings("Multiplayer (Host)", state.modeLabel());

    processGameLine("[16:17:52][gamestate.cpp:1005]: NEW YEAR: 1454", &state);
    try std.testing.expectEqual(@as(?u32, 1454), state.year);

    processGameLine("[16:18:05][diplomatic_action_war.cpp:482]: WAR: France declared war on Burgundy", &state);
    try std.testing.expectEqualStrings("At War with Burgundy", state.activeEvent().?);

    var d_buf: [256]u8 = undefined;
    var s_buf: [256]u8 = undefined;
    const p = state.formatPresence(&cfg.presence, &d_buf, &s_buf);
    try std.testing.expectEqualStrings("Playing as France (1454)", p.details);
    try std.testing.expectEqualStrings("At War with Burgundy · Multiplayer (Host) · v1.4.7", p.state.?);

    processGameLine("[16:18:25][country.cpp:6312]: DISASTER: succession_crisis starts in FRA", &state);
    try std.testing.expectEqualStrings("Disaster: Succession Crisis", state.activeEvent().?);

    processGameLine("[16:18:25][country.cpp:6312]: DISASTER: succession_crisis ends in FRA", &state);
    try std.testing.expectEqual(@as(?[]const u8, null), state.activeEvent());

    processDebugLine("[16:18:39][pdx_transition_task.cpp:138]: Running Transition SplashScreen->Empty", &state);
    try std.testing.expectEqual(gs.GamePhase.not_running, state.phase);
}

test "resolves New Country tag via CountryLookup and parses SITUATION start date" {
    const cfg_mod = @import("config.zig");
    var lookup = country_lookup_mod.CountryLookup.init(std.testing.allocator);
    defer lookup.deinit();
    _ = lookup.parseLocalizationContent("l_english:\n POR: \"Portugal\"\n");

    var state = gs.GameState{};
    processMultiplayerLine("New Country: POR", &state, &lookup);
    try std.testing.expectEqualStrings("POR", state.countryTag().?);
    try std.testing.expectEqualStrings("Portugal", state.countryName().?);
    try std.testing.expectEqual(gs.GamePhase.in_game, state.phase);

    processGameLine("[17:54:09][situation_manager.cpp:384]: SITUATION: Rise of the Turks starts on 1 May, 1337", &state);
    try std.testing.expectEqual(@as(?u32, 1337), state.year);
    try std.testing.expectEqualStrings("1 May, 1337", state.dateStr().?);

    const cfg = cfg_mod.Config{};
    var d_buf: [256]u8 = undefined;
    var s_buf: [256]u8 = undefined;
    const p = state.formatPresence(&cfg.presence, &d_buf, &s_buf);
    try std.testing.expectEqualStrings("Playing as Portugal (1337)", p.details);
}

test "refreshSaveMetadata reads continue_game.json version even when skipping country" {
    const sep = if (builtin.os.tag == .windows) "\\" else "/";
    var temp_root_buf: [512]u8 = undefined;
    const temp_root = if (builtin.os.tag == .windows)
        eu5_files.getEnvUtf8("TEMP", &temp_root_buf) orelse "."
    else
        "/tmp";

    var dir_buf: [600]u8 = undefined;
    const dir = root.bufPrintZ(&dir_buf, "{s}{s}eu5-rpc-test-cont", .{ temp_root, sep }) catch unreachable;
    eu5_files.ensureDirRecursive(dir);

    var cont_buf: [640]u8 = undefined;
    const cont_path = root.bufPrintZ(&cont_buf, "{s}{s}continue_game.json", .{ dir, sep }) catch unreachable;
    try std.testing.expect(eu5_files.writeFileAll(cont_path.ptr, "{\"rawGameVersion\":\"1.4.9\"}"));

    var state = gs.GameState{};
    var watcher = LogWatcher.init(dir, null);
    watcher.refreshSaveMetadata(&state, null, true);
    try std.testing.expectEqualStrings("1.4.9", state.gameVersion().?);
    try std.testing.expectEqual(@as(?[]const u8, null), state.countryName());
}

test "processes defending war, civil war, exploration, and observer lines" {
    var state = gs.GameState{};
    state.enterGame();
    state.setCountryName("Portugal");
    state.setCountryTag("POR");

    processGameLine("[12:00:00][war.cpp:10]: WAR: Castile declared war on Portugal", &state);
    try std.testing.expectEqualStrings("Defending vs. Castile", state.activeEvent().?);

    processGameLine("[12:01:00][cw.cpp:10]: CIVIL WAR: Portuguese Rebels against Portugal", &state);
    try std.testing.expectEqualStrings("In a Civil War", state.activeEvent().?);

    processGameLine("[12:02:00][exp.cpp:10]: EXPLORATION: Portugal discovered #L; Madeira!", &state);
    try std.testing.expectEqualStrings("Explored Madeira", state.activeEvent().?);

    processMultiplayerLine("_Player Is Observer: true", &state, null);
    try std.testing.expectEqual(true, state.observer);
    try std.testing.expectEqualStrings("Observer", state.modeLabel());

    processMultiplayerLine("Destroying gamestate", &state, null);
    try std.testing.expectEqual(@as(?[]const u8, null), state.activeEvent());
}
