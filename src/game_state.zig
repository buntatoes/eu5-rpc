// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const config = @import("config.zig");

pub const GamePhase = enum {
    not_running,
    loading,
    main_menu,
    lobby,
    in_game,

    pub fn name(self: GamePhase) []const u8 {
        return switch (self) {
            .not_running => "not_running",
            .loading => "loading",
            .main_menu => "main_menu",
            .lobby => "lobby",
            .in_game => "in_game",
        };
    }
};

/// Europa Universalis V spans six historical Ages beginning in 1337.
pub fn historicalAgeForYear(year: u32) ?[]const u8 {
    if (year < 1337) return null;
    if (year <= 1436) return "Age of Traditions";
    if (year <= 1536) return "Age of Renaissance";
    if (year <= 1636) return "Age of Discovery";
    if (year <= 1736) return "Age of Reformation";
    if (year <= 1836) return "Age of Absolutism";
    return "Age of Revolutions";
}

pub const RichPresenceUpdate = struct {
    phase: ?GamePhase = null,
    country_buf: [128]u8 = undefined,
    country_len: usize = 0,
    status_buf: [192]u8 = undefined,
    status_len: usize = 0,
    year: ?u32 = null,
    multiplayer: ?bool = null,
    observer: ?bool = null,

    pub fn country(self: *const RichPresenceUpdate) ?[]const u8 {
        if (self.country_len == 0) return null;
        return self.country_buf[0..self.country_len];
    }

    pub fn status(self: *const RichPresenceUpdate) ?[]const u8 {
        if (self.status_len == 0) return null;
        return self.status_buf[0..self.status_len];
    }

    pub fn setCountry(self: *RichPresenceUpdate, text: []const u8) void {
        const n = @min(text.len, self.country_buf.len);
        @memcpy(self.country_buf[0..n], text[0..n]);
        self.country_len = n;
    }

    pub fn setStatus(self: *RichPresenceUpdate, text: []const u8) void {
        const n = @min(text.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], text[0..n]);
        self.status_len = n;
    }
};

pub const FormattedPresence = struct {
    details: []const u8,
    state: ?[]const u8,
};

pub const GameState = struct {
    phase: GamePhase = .not_running,
    country_buf: [128]u8 = undefined,
    country_len: usize = 0,
    tag_buf: [32]u8 = undefined,
    tag_len: usize = 0,
    year: ?u32 = null,
    date_buf: [64]u8 = undefined,
    date_len: usize = 0,
    version_buf: [64]u8 = undefined,
    version_len: usize = 0,
    multiplayer: bool = false,
    multiplayer_host: bool = false,
    observer: bool = false,
    active_event_buf: [192]u8 = undefined,
    active_event_len: usize = 0,

    pub fn reset(self: *GameState) void {
        self.phase = .not_running;
        self.country_len = 0;
        self.tag_len = 0;
        self.year = null;
        self.date_len = 0;
        self.version_len = 0;
        self.multiplayer = false;
        self.multiplayer_host = false;
        self.observer = false;
        self.active_event_len = 0;
    }

    pub fn enterLoading(self: *GameState) void {
        self.phase = .loading;
        self.active_event_len = 0;
    }

    pub fn enterMainMenu(self: *GameState) void {
        self.phase = .main_menu;
        self.country_len = 0;
        self.tag_len = 0;
        self.year = null;
        self.date_len = 0;
        self.active_event_len = 0;
    }

    pub fn enterLobby(self: *GameState) void {
        self.phase = .lobby;
        self.active_event_len = 0;
    }

    pub fn enterGame(self: *GameState) void {
        self.phase = .in_game;
    }

    pub fn countryName(self: *const GameState) ?[]const u8 {
        if (self.country_len == 0) return null;
        return self.country_buf[0..self.country_len];
    }

    pub fn countryTag(self: *const GameState) ?[]const u8 {
        if (self.tag_len == 0) return null;
        return self.tag_buf[0..self.tag_len];
    }

    pub fn dateStr(self: *const GameState) ?[]const u8 {
        if (self.date_len == 0) return null;
        return self.date_buf[0..self.date_len];
    }

    pub fn gameVersion(self: *const GameState) ?[]const u8 {
        if (self.version_len == 0) return null;
        return self.version_buf[0..self.version_len];
    }

    pub fn activeEvent(self: *const GameState) ?[]const u8 {
        if (self.active_event_len == 0) return null;
        return self.active_event_buf[0..self.active_event_len];
    }

    pub fn setCountryName(self: *GameState, text: []const u8) void {
        const n = @min(text.len, self.country_buf.len);
        @memcpy(self.country_buf[0..n], text[0..n]);
        self.country_len = n;
    }

    pub fn clearCountry(self: *GameState) void {
        self.country_len = 0;
        self.tag_len = 0;
    }

    pub fn setCountryTag(self: *GameState, text: []const u8) void {
        const n = @min(text.len, self.tag_buf.len);
        @memcpy(self.tag_buf[0..n], text[0..n]);
        self.tag_len = n;
    }

    pub fn setDateStr(self: *GameState, text: []const u8) void {
        const n = @min(text.len, self.date_buf.len);
        @memcpy(self.date_buf[0..n], text[0..n]);
        self.date_len = n;
    }

    pub fn setGameVersion(self: *GameState, text: []const u8) void {
        const n = @min(text.len, self.version_buf.len);
        @memcpy(self.version_buf[0..n], text[0..n]);
        self.version_len = n;
    }

    pub fn setActiveEvent(self: *GameState, text: []const u8) void {
        const n = @min(text.len, self.active_event_buf.len);
        @memcpy(self.active_event_buf[0..n], text[0..n]);
        self.active_event_len = n;
    }

    pub fn clearActiveEvent(self: *GameState) void {
        self.active_event_len = 0;
    }

    pub fn applySteamUpdate(self: *GameState, upd: *const RichPresenceUpdate) void {
        if (upd.phase) |p| self.phase = p;
        if (upd.multiplayer) |mp| self.multiplayer = mp;
        if (upd.observer) |obs| self.observer = obs;

        if (self.phase == .main_menu) {
            self.country_len = 0;
            self.tag_len = 0;
            self.year = null;
            self.active_event_len = 0;
            return;
        }

        if (upd.country()) |c| {
            const existing = self.countryName() orelse "";
            if (!std.mem.eql(u8, existing, c)) {
                self.setCountryName(c);
                self.tag_len = 0;
            }
        }
        if (upd.year) |y| self.year = y;
        if (upd.status()) |st| self.setActiveEvent(st);
    }

    pub fn modeLabel(self: *const GameState) []const u8 {
        if (self.observer) {
            return if (self.multiplayer) "Multiplayer Observer" else "Observer";
        } else if (self.multiplayer) {
            return if (self.multiplayer_host) "Multiplayer (Host)" else "Multiplayer";
        } else {
            return "Singleplayer";
        }
    }

    pub fn historicalAge(self: *const GameState) ?[]const u8 {
        const y = self.year orelse return null;
        return historicalAgeForYear(y);
    }

    pub fn formatPresence(
        self: *const GameState,
        pres_cfg: *const config.PresenceConfig,
        details_buf: []u8,
        state_buf: []u8,
    ) FormattedPresence {
        const status_cfg = &pres_cfg.status;
        var year_buf: [16]u8 = undefined;
        const year_label = if (self.year) |y|
            std.fmt.bufPrint(&year_buf, "{d}", .{y}) catch "1337"
        else
            "1337";
        const age_label = self.historicalAge() orelse "";

        switch (self.phase) {
            .not_running => return .{
                .details = copyTrunc(details_buf, status_cfg.game_not_running.slice()),
                .state = null,
            },
            .loading => return .{
                .details = copyTrunc(details_buf, status_cfg.loading.slice()),
                .state = self.versionSuffix(pres_cfg, state_buf),
            },
            .main_menu => return .{
                .details = copyTrunc(details_buf, status_cfg.in_main_menu.slice()),
                .state = self.versionSuffix(pres_cfg, state_buf),
            },
            .lobby => {
                const details = if (self.countryName()) |c|
                    std.fmt.bufPrint(details_buf, "Choosing Country: {s}", .{c}) catch "In Country Selection Lobby"
                else
                    copyTrunc(details_buf, "In Country Selection Lobby");

                var ver_buf: [72]u8 = undefined;
                const state = if (self.versionSuffix(pres_cfg, &ver_buf)) |vs|
                    std.fmt.bufPrint(state_buf, "{s} · {s}", .{ self.modeLabel(), vs }) catch self.modeLabel()
                else
                    copyTrunc(state_buf, self.modeLabel());
                return .{ .details = details, .state = state };
            },
            .in_game => {
                const vars = config.TemplateVars{
                    .country = self.countryName() orelse "",
                    .tag = self.countryTag() orelse "",
                    .year = year_label,
                    .date = self.dateStr() orelse year_label,
                    .age = age_label,
                };

                const tmpl = if (self.observer)
                    status_cfg.observing.slice()
                else if (self.countryName() != null)
                    status_cfg.in_game_with_country.slice()
                else
                    status_cfg.in_game_unknown_country.slice();

                const details = config.applyVars(details_buf, tmpl, vars);

                var pos: usize = 0;
                var has_event_or_age = false;

                if (pres_cfg.show_live_events) {
                    if (self.activeEvent()) |ev| {
                        pos = appendPart(state_buf, pos, ev);
                        has_event_or_age = true;
                    }
                }
                if (pres_cfg.show_historical_age and age_label.len > 0 and !has_event_or_age) {
                    pos = appendPart(state_buf, pos, age_label);
                }
                pos = appendPart(state_buf, pos, self.modeLabel());
                if (pres_cfg.show_game_version) {
                    if (self.gameVersion()) |v| {
                        var vbuf: [72]u8 = undefined;
                        if (std.fmt.bufPrint(&vbuf, "v{s}", .{v})) |vs| {
                            pos = appendPart(state_buf, pos, vs);
                        } else |_| {}
                    }
                }

                return .{
                    .details = details,
                    .state = if (pos > 0) state_buf[0..pos] else null,
                };
            },
        }
    }

    fn versionSuffix(self: *const GameState, pres_cfg: *const config.PresenceConfig, buf: []u8) ?[]const u8 {
        if (!pres_cfg.show_game_version) return null;
        const v = self.gameVersion() orelse return null;
        return std.fmt.bufPrint(buf, "v{s}", .{v}) catch null;
    }
};

fn copyTrunc(buf: []u8, src: []const u8) []const u8 {
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}

fn appendPart(buf: []u8, pos: usize, part: []const u8) usize {
    if (part.len == 0) return pos;
    var p = pos;
    if (p > 0) {
        const sep = " · ";
        if (p + sep.len <= buf.len) {
            @memcpy(buf[p .. p + sep.len], sep);
            p += sep.len;
        }
    }
    const copy_n = @min(part.len, buf.len - p);
    @memcpy(buf[p .. p + copy_n], part[0..copy_n]);
    return p + copy_n;
}

test "EU5 six historical ages from 1337 onward" {
    try std.testing.expectEqualStrings("Age of Traditions", historicalAgeForYear(1337).?);
    try std.testing.expectEqualStrings("Age of Renaissance", historicalAgeForYear(1453).?);
    try std.testing.expectEqualStrings("Age of Discovery", historicalAgeForYear(1550).?);
    try std.testing.expectEqualStrings("Age of Reformation", historicalAgeForYear(1648).?);
    try std.testing.expectEqualStrings("Age of Absolutism", historicalAgeForYear(1750).?);
    try std.testing.expectEqualStrings("Age of Revolutions", historicalAgeForYear(1837).?);
    try std.testing.expectEqual(@as(?[]const u8, null), historicalAgeForYear(1200));
}

test "game state formats presence for menus, lobby, and in-game modes" {
    const cfg = config.Config{};
    var state = GameState{};
    state.setGameVersion("1.4.9");
    state.enterGame();
    state.setCountryName("France");
    state.setCountryTag("FRA");
    state.year = 1454;
    state.multiplayer = true;
    state.multiplayer_host = true;
    state.setActiveEvent("At War with Burgundy");

    var d_buf: [256]u8 = undefined;
    var s_buf: [256]u8 = undefined;
    const p1 = state.formatPresence(&cfg.presence, &d_buf, &s_buf);
    try std.testing.expectEqualStrings("Playing as France (1454)", p1.details);
    try std.testing.expectEqualStrings("At War with Burgundy · Multiplayer (Host) · v1.4.9", p1.state.?);

    state.clearActiveEvent();
    const p2 = state.formatPresence(&cfg.presence, &d_buf, &s_buf);
    try std.testing.expectEqualStrings("Age of Renaissance · Multiplayer (Host) · v1.4.9", p2.state.?);
}
