// SPDX-License-Identifier: GPL-3.0-only
// Passively reads the local Steam client's live Rich Presence strings for Europa Universalis V
// via steamclient64.dll (Windows) or steamclient.so (Linux).
// Supports all 11 official EU5 languages:
//   English, Brazilian Portuguese, French, German, Japanese, Korean, Polish,
//   Russian, Simplified Chinese, Spanish, and Turkish.
// 100% read-only & VAC-safe: never reads game memory, never injects DLLs, never calls SteamAPI_Init.
const std = @import("std");
const builtin = @import("builtin");
const gs = @import("game_state.zig");
const proc = @import("process.zig");
const eu5_files = @import("eu5_files.zig");
const root = @import("root.zig");

const win = if (builtin.os.tag == .windows) struct {
    const HMODULE = ?*anyopaque;
    extern "kernel32" fn SetEnvironmentVariableA(lpName: [*:0]const u8, lpValue: [*:0]const u8) callconv(.winapi) i32;
    extern "kernel32" fn SetDllDirectoryW(lpPathName: ?[*:0]const u16) callconv(.winapi) i32;
    extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) HMODULE;
    extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
} else struct {};

const posix = if (builtin.os.tag != .windows) struct {
    const RTLD_NOW: c_int = 2;
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn dlopen(filename: ?[*:0]const u8, flags: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
} else struct {};

// Verified x64 vtable indices for ISteamClient021 / ISteamUser023 / ISteamFriends017
const VT_CREATE_PIPE = 0;
const VT_RELEASE_PIPE = 1;
const VT_CONNECT_GLOBAL_USER = 2;
const VT_RELEASE_USER = 4;
const VT_GET_STEAM_USER = 5;
const VT_GET_STEAM_FRIENDS = 8;

const VT_USER_GET_STEAM_ID = 2;

const VT_FRIENDS_GET_RP = 45;
const VT_FRIENDS_GET_RP_KEY_COUNT = 46;
const VT_FRIENDS_GET_RP_KEY_AT = 47;
const VT_FRIENDS_REQUEST_RP = 48;

const CreateInterfaceFn = *const fn ([*:0]const u8, *c_int) callconv(.c) ?*anyopaque;
const CreatePipeFn = *const fn (*anyopaque) callconv(.c) i32;
const ReleasePipeFn = *const fn (*anyopaque, i32) callconv(.c) u8;
const ConnectUserFn = *const fn (*anyopaque, i32) callconv(.c) i32;
const ReleaseUserFn = *const fn (*anyopaque, i32, i32) callconv(.c) void;
const GetIfaceFn = *const fn (*anyopaque, i32, i32, [*:0]const u8) callconv(.c) ?*anyopaque;
const GetSteamIdWinFn = *const fn (*anyopaque, *u64) callconv(.c) *u64;
const GetSteamIdSysvFn = *const fn (*anyopaque) callconv(.c) u64;
const GetRpValFn = *const fn (*anyopaque, u64, [*:0]const u8) callconv(.c) ?[*:0]const u8;
const GetRpCountFn = *const fn (*anyopaque, u64) callconv(.c) c_int;
const GetRpKeyFn = *const fn (*anyopaque, u64, c_int) callconv(.c) ?[*:0]const u8;
const RequestRpFn = *const fn (*anyopaque, u64) callconv(.c) void;

fn vtableSlot(obj: *anyopaque, comptime idx: usize, comptime FnType: type) FnType {
    const vtable_ptr: [*]const usize = @as(*const [*]const usize, @ptrCast(@alignCast(obj))).*;
    return @ptrFromInt(vtable_ptr[idx]);
}

// Official EU5 localized Rich Presence strings across all 11 supported languages.
const MAIN_MENU_STRINGS = [_][]const u8{
    "in main menu",
    "no menu principal",
    "dans le menu principal",
    "im hauptmenü",
    "メインメニュー",
    "메인 메뉴",
    "w menu głównym",
    "в главном меню",
    "位于主菜单",
    "en el menú principal",
    "ana menüde",
};

const LOBBY_STRINGS = [_][]const u8{
    "in lobby",
    "no lobby",
    "dans le salon",
    "in der lobby",
    "ロビー",
    "로비",
    "w lobby",
    "в лобби",
    "位于多人游戏大厅",
    "en sala",
    "lobide",
};

const MULTIPLAYER_TAGS = [_][]const u8{
    "multiplayer",
    "multijogador",
    "multijoueur",
    "mehrspieler",
    "マルチプレイ",
    "멀티플레이어",
    "gra wieloosobowa",
    "многопользовательская игра",
    "多人游戏",
    "multijugador",
    "çok oyunculu",
};

const OBSERVER_KEYWORDS = [_][]const u8{
    "observing",
    "observando",
    "observe ",
    "beobachtet",
    "観測中",
    "관전 중",
    "obserwuje",
    "наблюдает",
    "观察世界",
    "izliyor",
};

fn foldCodepoint(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    if ((cp >= 0x00C0 and cp <= 0x00D6) or (cp >= 0x00D8 and cp <= 0x00DE)) return cp + 32;
    if (cp >= 0x0410 and cp <= 0x042F) return cp + 0x20;
    return switch (cp) {
        0x0104 => 0x0105, // Ą -> ą
        0x0106 => 0x0107, // Ć -> ć
        0x0118 => 0x0119, // Ę -> ę
        0x011E => 0x011F, // Ğ -> ğ
        0x0130 => 'i', // İ -> i
        0x0141 => 0x0142, // Ł -> ł
        0x0143 => 0x0144, // Ń -> ń
        0x015A => 0x015B, // Ś -> ś
        0x015E => 0x015F, // Ş -> ş
        0x0179 => 0x017A, // Ź -> ź
        0x017B => 0x017C, // Ż -> ż
        0x0401 => 0x0451, // Ё -> ё
        else => cp,
    };
}

fn nextCodepoint(s: []const u8, pos: usize) struct { cp: u21, next: usize } {
    const len = std.unicode.utf8ByteSequenceLength(s[pos]) catch 1;
    if (pos + len > s.len) return .{ .cp = s[pos], .next = pos + 1 };
    const cp = std.unicode.utf8Decode(s[pos .. pos + len]) catch s[pos];
    return .{ .cp = cp, .next = pos + len };
}

fn utf8Lower(src: []const u8, out_buf: []u8) []const u8 {
    var pos: usize = 0;
    var out_len: usize = 0;
    while (pos < src.len) {
        const step = nextCodepoint(src, pos);
        pos = step.next;
        const low = foldCodepoint(step.cp);
        var enc: [4]u8 = undefined;
        const enc_len = std.unicode.utf8Encode(low, &enc) catch continue;
        if (out_len + enc_len > out_buf.len) break;
        @memcpy(out_buf[out_len .. out_len + enc_len], enc[0..enc_len]);
        out_len += enc_len;
    }
    return out_buf[0..out_len];
}

/// Checks if `haystack[start..]` starts with `needle_lower` case-insensitively (UTF-8 aware).
/// Returns the byte end index in `haystack` on match.
fn matchPrefixIgnoreCase(haystack: []const u8, start: usize, needle_lower: []const u8) ?usize {
    var hi = start;
    var ni: usize = 0;
    while (ni < needle_lower.len) {
        if (hi >= haystack.len) return null;
        const hs = nextCodepoint(haystack, hi);
        const ns = nextCodepoint(needle_lower, ni);
        if (foldCodepoint(hs.cp) != ns.cp) return null;
        hi = hs.next;
        ni = ns.next;
    }
    return hi;
}

fn eqlIgnoreCaseUtf8(a: []const u8, b_lower: []const u8) bool {
    const end = matchPrefixIgnoreCase(a, 0, b_lower) orelse return false;
    return end == a.len;
}

fn isSpaceOrNbspAt(s: []const u8, pos: usize) ?usize {
    if (pos >= s.len) return null;
    if (s[pos] == ' ' or s[pos] == '\t') return pos + 1;
    if (pos + 1 < s.len and s[pos] == 0xC2 and s[pos + 1] == 0xA0) return pos + 2;
    return null;
}

fn trimSpacesAndNbspEnd(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        if (s[end - 1] == ' ' or s[end - 1] == '\t') {
            end -= 1;
        } else if (end >= 2 and s[end - 2] == 0xC2 and s[end - 1] == 0xA0) {
            end -= 2;
        } else {
            break;
        }
    }
    return s[0..end];
}

fn isPdxTagChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
}

/// Strips Paradox rich-text color/formatting directives (`#V ... #!`) unless text is a raw `#main_menu`/`#in_lobby`/`#playing` token.
pub fn cleanPdxText(src: []const u8, out_buf: []u8) []const u8 {
    const preserve_tokens = std.mem.startsWith(u8, src, "#main_menu") or
        std.mem.startsWith(u8, src, "#in_lobby") or
        std.mem.startsWith(u8, src, "#playing");

    var out_len: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '#' and i + 1 < src.len and src[i + 1] == '!') {
            i += 2;
            continue;
        }
        if (!preserve_tokens and src[i] == '#' and i + 1 < src.len and isPdxTagChar(src[i + 1])) {
            i += 1;
            while (i < src.len and isPdxTagChar(src[i])) : (i += 1) {}
            while (i < src.len and (src[i] == ' ' or src[i] == '\t')) : (i += 1) {}
            continue;
        }
        if (out_len < out_buf.len) {
            out_buf[out_len] = src[i];
            out_len += 1;
        }
        i += 1;
    }
    return std.mem.trim(u8, out_buf[0..out_len], " \t\r\n");
}

const MpStrip = struct {
    core: []const u8,
    multiplayer: bool,
};

fn stripMultiplayerTag(text: []const u8) MpStrip {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const close_len: usize = if (std.mem.endsWith(u8, trimmed, ")"))
        1
    else if (std.mem.endsWith(u8, trimmed, "）"))
        "）".len
    else
        return .{ .core = trimmed, .multiplayer = false };

    const before_close = trimmed[0 .. trimmed.len - close_len];
    // Find last '(' or '（'
    const open_ascii = std.mem.lastIndexOfScalar(u8, before_close, '(');
    const open_full = std.mem.lastIndexOf(u8, before_close, "（");

    var open_pos: usize = 0;
    var open_len: usize = 0;
    if (open_ascii != null and (open_full == null or open_ascii.? > open_full.?)) {
        open_pos = open_ascii.?;
        open_len = 1;
    } else if (open_full) |of| {
        open_pos = of;
        open_len = "（".len;
    } else {
        return .{ .core = trimmed, .multiplayer = false };
    }

    const inside = before_close[open_pos + open_len ..];
    for (MULTIPLAYER_TAGS) |tag| {
        if (eqlIgnoreCaseUtf8(inside, tag)) {
            return .{
                .core = std.mem.trim(u8, trimmed[0..open_pos], " \t\r\n"),
                .multiplayer = true,
            };
        }
    }
    return .{ .core = trimmed, .multiplayer = false };
}

fn parseYear(s: []const u8) ?u32 {
    if (s.len < 3 or s.len > 4) return null;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
    }
    return std.fmt.parseInt(u32, s, 10) catch null;
}

const CommaYear = struct {
    prefix: []const u8,
    year: u32,
};

/// Matches `(.+?)[,、，]\s*(\d{3,4})$` where `allow_cjk_comma` toggles `、` and `，`.
fn splitTrailingCommaYear(text: []const u8, allow_cjk_comma: bool) ?CommaYear {
    if (text.len < 4) return null;
    var d_start = text.len;
    while (d_start > 0 and text[d_start - 1] >= '0' and text[d_start - 1] <= '9') : (d_start -= 1) {}
    const digits = text[d_start..];
    const year = parseYear(digits) orelse return null;

    var p = d_start;
    while (p > 0 and (text[p - 1] == ' ' or text[p - 1] == '\t')) : (p -= 1) {}

    if (p >= 1 and text[p - 1] == ',') {
        const prefix = std.mem.trim(u8, text[0 .. p - 1], " \t");
        if (prefix.len > 0) return .{ .prefix = prefix, .year = year };
    }
    if (allow_cjk_comma) {
        if (p >= "、".len and std.mem.eql(u8, text[p - "、".len .. p], "、")) {
            const prefix = std.mem.trim(u8, text[0 .. p - "、".len], " \t");
            if (prefix.len > 0) return .{ .prefix = prefix, .year = year };
        }
        if (p >= "，".len and std.mem.eql(u8, text[p - "，".len .. p], "，")) {
            const prefix = std.mem.trim(u8, text[0 .. p - "，".len], " \t");
            if (prefix.len > 0) return .{ .prefix = prefix, .year = year };
        }
    }
    return null;
}

const SplitPair = struct {
    left: []const u8,
    right: []const u8,
};

/// Finds earliest whitespace-bounded occurrence of any connector in `connectors_lower` (case-insensitive UTF-8).
fn splitByWordConnectors(text: []const u8, connectors_lower: []const []const u8) ?SplitPair {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == ' ' or text[i] == '\t') {
            const left = std.mem.trim(u8, text[0..i], " \t");
            var ws_end = i;
            while (ws_end < text.len and (text[ws_end] == ' ' or text[ws_end] == '\t')) : (ws_end += 1) {}
            if (left.len > 0 and ws_end < text.len) {
                for (connectors_lower) |conn| {
                    if (matchPrefixIgnoreCase(text, ws_end, conn)) |conn_end| {
                        if (conn_end < text.len and (text[conn_end] == ' ' or text[conn_end] == '\t')) {
                            const right = std.mem.trim(u8, text[conn_end..], " \t");
                            if (right.len > 0) return .{ .left = left, .right = right };
                        }
                    }
                }
            }
            i = ws_end;
        } else {
            const step = nextCodepoint(text, i);
            i = step.next;
        }
    }
    return null;
}

fn playingResult(country: []const u8, year: u32, status_opt: ?[]const u8, mp: bool) gs.RichPresenceUpdate {
    var upd = gs.RichPresenceUpdate{
        .phase = .in_game,
        .year = year,
        .multiplayer = mp,
        .observer = false,
    };
    const c = std.mem.trim(u8, country, " \t");
    if (c.len > 0) upd.setCountry(c);
    if (status_opt) |s| {
        const st = std.mem.trim(u8, s, " \t");
        if (st.len > 0) upd.setStatus(st);
    }
    return upd;
}

pub fn isObserverText(text: []const u8) bool {
    var low_buf: [256]u8 = undefined;
    const low = utf8Lower(text, &low_buf);
    for (OBSERVER_KEYWORDS) |kw| {
        if (std.mem.indexOf(u8, low, kw) != null) return true;
    }
    return false;
}

fn splitChineseStatus(body: []const u8) ?SplitPair {
    const exact_statuses = [_][]const u8{
        "破产",
        "处于摄政时期",
        "时代霸主",
        "殖民新土地",
        "统治国家",
    };
    const prefix_statuses = [_][]const u8{
        "经历",
        "输掉对抗",
        "赢得对抗",
        "领导",
        "患有",
        "隶属于",
    };

    var pos: usize = 0;
    while (pos < body.len) {
        const step = nextCodepoint(body, pos);
        pos = step.next;
        if (pos == 0 or pos >= body.len) break;

        const st = body[pos..];
        for (exact_statuses) |ex| {
            if (std.mem.eql(u8, st, ex)) return .{ .left = body[0..pos], .right = st };
        }
        for (prefix_statuses) |pre| {
            if (std.mem.startsWith(u8, st, pre) and st.len > pre.len) {
                return .{ .left = body[0..pos], .right = st };
            }
        }
        if (std.mem.startsWith(u8, st, "与") and std.mem.endsWith(u8, st, "交战") and st.len > "与".len + "交战".len) {
            return .{ .left = body[0..pos], .right = st };
        }
    }
    return null;
}

/// Parses EU5 Steam Rich Presence key/value fields across all 11 official languages plus raw token fallbacks.
pub fn parsePresenceFields(
    status_raw: ?[]const u8,
    display_raw: ?[]const u8,
    country_raw: ?[]const u8,
    year_raw: ?[]const u8,
) ?gs.RichPresenceUpdate {
    var s_buf: [256]u8 = undefined;
    var d_buf: [256]u8 = undefined;
    var c_buf: [128]u8 = undefined;
    var y_buf: [32]u8 = undefined;

    const status_clean = if (status_raw) |s| cleanPdxText(s, &s_buf) else "";
    const display_clean = if (display_raw) |d| cleanPdxText(d, &d_buf) else "";
    const country_clean = if (country_raw) |c| cleanPdxText(c, &c_buf) else "";
    const year_clean = if (year_raw) |y| cleanPdxText(y, &y_buf) else "";

    const text = if (status_clean.len > 0) status_clean else display_clean;

    // 1. Check formatted EU5 localized Rich Presence string across all 11 languages
    if (text.len > 0 and text[0] != '#') {
        const stripped = stripMultiplayerTag(text);
        const core = stripped.core;
        const mp = stripped.multiplayer;

        var low_buf: [256]u8 = undefined;
        const lower = utf8Lower(core, &low_buf);

        for (MAIN_MENU_STRINGS) |mm| {
            if (std.mem.eql(u8, lower, mm)) {
                return .{
                    .phase = .main_menu,
                    .multiplayer = false,
                    .observer = false,
                };
            }
        }
        for (LOBBY_STRINGS) |lb| {
            if (std.mem.eql(u8, lower, lb)) {
                return .{
                    .phase = .lobby,
                    .multiplayer = mp,
                    .observer = false,
                };
            }
        }

        // Russian: "<STATUS> за державу <COUNTRY>, <YEAR>[\s\u00A0]*год"
        if (std.mem.endsWith(u8, lower, "год")) {
            // Find byte length of trailing "год" (case-insensitive, 6 bytes in UTF-8)
            const god_len = "год".len;
            if (core.len > god_len) {
                const before_god = trimSpacesAndNbspEnd(core[0 .. core.len - god_len]);
                if (splitTrailingCommaYear(before_god, false)) |cy| {
                    const ru_conns = [_][]const u8{"за державу"};
                    if (splitByWordConnectors(cy.prefix, &ru_conns)) |sp| {
                        return playingResult(sp.right, cy.year, sp.left, mp);
                    }
                }
            }
        }

        // EN, PT-BR, FR, DE, PL, ES: "<STATUS> (en tant que|as|como|als|jako) <COUNTRY>, <YEAR>"
        if (splitTrailingCommaYear(core, false)) |cy| {
            const western_conns = [_][]const u8{
                "en tant que",
                "as",
                "como",
                "als",
                "jako",
            };
            if (splitByWordConnectors(cy.prefix, &western_conns)) |sp| {
                return playingResult(sp.right, cy.year, sp.left, mp);
            }

            // Turkish: "<COUNTRY> olarak <STATUS>, <YEAR>"
            const tr_conns = [_][]const u8{"olarak"};
            if (splitByWordConnectors(cy.prefix, &tr_conns)) |sp| {
                return playingResult(sp.left, cy.year, sp.right, mp);
            }
        }

        // Japanese: "<COUNTRY>として<STATUS>[、,]\s*<YEAR>"
        if (splitTrailingCommaYear(core, true)) |cy| {
            if (std.mem.indexOf(u8, cy.prefix, "として")) |idx| {
                const country = cy.prefix[0..idx];
                const st = cy.prefix[idx + "として".len ..];
                if (country.len > 0 and st.len > 0) {
                    return playingResult(country, cy.year, st, mp);
                }
            }
        }

        // Korean: "<YEAR>, <COUNTRY>(으)로 <STATUS>" (or "<COUNTRY>으로/로 <STATUS>")
        if (std.mem.indexOfScalar(u8, core, ',')) |comma_idx| {
            if (parseYear(core[0..comma_idx])) |yr| {
                const rest = std.mem.trimStart(u8, core[comma_idx + 1 ..], " \t");
                const ko_particles = [_][]const u8{ "(으)로", "으로", "로" };
                var pos: usize = 0;
                while (pos < rest.len) {
                    const step = nextCodepoint(rest, pos);
                    pos = step.next;
                    if (pos == 0 or pos >= rest.len) break;
                    for (ko_particles) |part| {
                        if (std.mem.startsWith(u8, rest[pos..], part)) {
                            const after_part = pos + part.len;
                            if (after_part < rest.len and (rest[after_part] == ' ' or rest[after_part] == '\t')) {
                                const st = std.mem.trimStart(u8, rest[after_part..], " \t");
                                if (st.len > 0) {
                                    return playingResult(rest[0..pos], yr, st, mp);
                                }
                            }
                        }
                    }
                }
            }
        }

        // Simplified Chinese: "作为<COUNTRY><STATUS>[，,]\s*<YEAR>年"
        if (std.mem.startsWith(u8, core, "作为") and std.mem.endsWith(u8, core, "年")) {
            const inner = core["作为".len .. core.len - "年".len];
            if (splitTrailingCommaYear(inner, true)) |cy| {
                if (splitChineseStatus(cy.prefix)) |sp| {
                    return playingResult(sp.left, cy.year, sp.right, mp);
                }
                return playingResult(cy.prefix, cy.year, null, mp);
            }
        }

        // Observer tail year across all 11 languages: "<TEXT>[,、，]\s*<YEAR>(?:[\s\u00A0]*год|年)?"
        {
            var body = core;
            if (std.mem.endsWith(u8, lower, "год") and body.len > "год".len) {
                body = trimSpacesAndNbspEnd(body[0 .. body.len - "год".len]);
            } else if (std.mem.endsWith(u8, body, "年")) {
                body = body[0 .. body.len - "年".len];
            }
            if (splitTrailingCommaYear(body, true)) |cy| {
                var upd = gs.RichPresenceUpdate{
                    .phase = .in_game,
                    .year = cy.year,
                    .multiplayer = mp,
                    .observer = isObserverText(cy.prefix),
                };
                upd.setStatus(cy.prefix);
                return upd;
            }
        }

        // Observer head year (Korean): "<YEAR>, <TEXT>"
        if (std.mem.indexOfScalar(u8, core, ',')) |comma_idx| {
            if (parseYear(core[0..comma_idx])) |yr| {
                const st = std.mem.trim(u8, core[comma_idx + 1 ..], " \t");
                if (st.len > 0) {
                    var upd = gs.RichPresenceUpdate{
                        .phase = .in_game,
                        .year = yr,
                        .multiplayer = mp,
                        .observer = isObserverText(st),
                    };
                    upd.setStatus(st);
                    return upd;
                }
            }
        }
    }

    // 2. Fallback for raw token-style Steam Rich Presence keys (#playing + COUNTRY/YEAR/STATUS)
    var d_low_buf: [128]u8 = undefined;
    const d_lower = utf8Lower(display_clean, &d_low_buf);
    const year = parseYear(year_clean);

    const phase: ?gs.GamePhase = if (std.mem.eql(u8, d_lower, "#main_menu"))
        .main_menu
    else if (std.mem.eql(u8, d_lower, "#in_lobby"))
        .lobby
    else if (std.mem.eql(u8, d_lower, "#playing") or
        std.mem.eql(u8, d_lower, "#playing_mp") or
        std.mem.eql(u8, d_lower, "#playing_observer") or
        std.mem.eql(u8, d_lower, "#playing_observer_mp"))
        .in_game
    else if (country_clean.len > 0)
        .in_game
    else
        null;

    if (phase == null and country_clean.len == 0 and year == null) return null;

    var upd = gs.RichPresenceUpdate{
        .phase = phase,
        .year = year,
        .multiplayer = std.mem.endsWith(u8, d_lower, "_mp"),
        .observer = std.mem.indexOf(u8, d_lower, "observer") != null,
    };
    if (country_clean.len > 0) upd.setCountry(country_clean);
    if (status_clean.len > 0) upd.setStatus(status_clean);
    return upd;
}

pub const SteamRichPresence = struct {
    connected: bool = false,
    client_ptr: ?*anyopaque = null,
    pipe: i32 = 0,
    user: i32 = 0,
    steam_friends: ?*anyopaque = null,
    steam_id: u64 = 0,

    pub fn poll(self: *SteamRichPresence) ?gs.RichPresenceUpdate {
        if (!proc.eu5Running()) {
            if (self.connected) self.disconnect();
            return null;
        }

        if (!self.connected) {
            self.connect();
        }
        if (!self.connected) return null;

        const sf = self.steam_friends orelse return null;
        if (self.steam_id == 0) return null;

        const req_fn = vtableSlot(sf, VT_FRIENDS_REQUEST_RP, RequestRpFn);
        const cnt_fn = vtableSlot(sf, VT_FRIENDS_GET_RP_KEY_COUNT, GetRpCountFn);
        const key_fn = vtableSlot(sf, VT_FRIENDS_GET_RP_KEY_AT, GetRpKeyFn);
        const val_fn = vtableSlot(sf, VT_FRIENDS_GET_RP, GetRpValFn);

        req_fn(sf, self.steam_id);
        const count = cnt_fn(sf, self.steam_id);
        if (count <= 0 or count > 64) return null;

        var status_buf: [256]u8 = undefined;
        var status_len: usize = 0;
        var display_buf: [256]u8 = undefined;
        var display_len: usize = 0;
        var country_buf: [128]u8 = undefined;
        var country_len: usize = 0;
        var year_buf: [32]u8 = undefined;
        var year_len: usize = 0;

        var i: c_int = 0;
        while (i < count) : (i += 1) {
            const kp = key_fn(sf, self.steam_id, i) orelse continue;
            const k = std.mem.span(kp);
            if (k.len == 0) continue;
            const vp = val_fn(sf, self.steam_id, kp) orelse continue;
            const v = std.mem.span(vp);
            if (v.len == 0) continue;

            if (std.ascii.eqlIgnoreCase(k, "status")) {
                const n = @min(v.len, status_buf.len);
                @memcpy(status_buf[0..n], v[0..n]);
                status_len = n;
            } else if (std.ascii.eqlIgnoreCase(k, "steam_display")) {
                const n = @min(v.len, display_buf.len);
                @memcpy(display_buf[0..n], v[0..n]);
                display_len = n;
            } else if (std.ascii.eqlIgnoreCase(k, "country")) {
                const n = @min(v.len, country_buf.len);
                @memcpy(country_buf[0..n], v[0..n]);
                country_len = n;
            } else if (std.ascii.eqlIgnoreCase(k, "year")) {
                const n = @min(v.len, year_buf.len);
                @memcpy(year_buf[0..n], v[0..n]);
                year_len = n;
            }
        }

        return parsePresenceFields(
            if (status_len > 0) status_buf[0..status_len] else null,
            if (display_len > 0) display_buf[0..display_len] else null,
            if (country_len > 0) country_buf[0..country_len] else null,
            if (year_len > 0) year_buf[0..year_len] else null,
        );
    }

    pub fn disconnect(self: *SteamRichPresence) void {
        if (self.connected) {
            if (self.client_ptr) |cp| {
                if (self.pipe > 0 and self.user > 0) {
                    const rel_user = vtableSlot(cp, VT_RELEASE_USER, ReleaseUserFn);
                    rel_user(cp, self.pipe, self.user);
                }
                if (self.pipe > 0) {
                    const rel_pipe = vtableSlot(cp, VT_RELEASE_PIPE, ReleasePipeFn);
                    _ = rel_pipe(cp, self.pipe);
                }
            }
        }
        self.connected = false;
        self.client_ptr = null;
        self.pipe = 0;
        self.user = 0;
        self.steam_friends = null;
        self.steam_id = 0;
    }

    fn connect(self: *SteamRichPresence) void {
        if (@sizeOf(usize) != 8) return;

        // Scope passive Steam IPC pipe to EU5 (AppID 3450310) without SteamAPI_Init
        if (builtin.os.tag == .windows) {
            _ = win.SetEnvironmentVariableA("SteamAppId", root.EU5_STEAM_APP_ID);
            _ = win.SetEnvironmentVariableA("SteamGameId", root.EU5_STEAM_APP_ID);
        } else {
            _ = posix.setenv("SteamAppId", root.EU5_STEAM_APP_ID, 1);
            _ = posix.setenv("SteamGameId", root.EU5_STEAM_APP_ID, 1);
        }

        var path_buf: [512]u8 = undefined;
        const lib_path = eu5_files.findSteamClientLib(&path_buf) orelse return;

        const create_iface: CreateInterfaceFn = blk: {
            if (builtin.os.tag == .windows) {
                if (std.mem.lastIndexOfAny(u8, lib_path, "\\/")) |sep| {
                    var dir_w: [1024]u16 = undefined;
                    if (eu5_files.utf8ToUtf16Z(lib_path[0..sep], &dir_w)) |dw| {
                        _ = win.SetDllDirectoryW(dw.ptr);
                    }
                }
                var lib_w: [1024]u16 = undefined;
                const lw = eu5_files.utf8ToUtf16Z(lib_path, &lib_w) orelse return;
                const h = win.LoadLibraryW(lw.ptr) orelse return;
                const sym = win.GetProcAddress(h, "CreateInterface") orelse return;
                break :blk @ptrCast(@alignCast(sym));
            } else {
                var lib_z: [513]u8 = undefined;
                @memcpy(lib_z[0..lib_path.len], lib_path);
                lib_z[lib_path.len] = 0;
                const h = posix.dlopen(@ptrCast(&lib_z), posix.RTLD_NOW) orelse return;
                const sym = posix.dlsym(h, "CreateInterface") orelse return;
                break :blk @ptrCast(@alignCast(sym));
            }
        };

        var rc: c_int = 0;
        const cp = create_iface("SteamClient021", &rc) orelse return;

        const create_pipe = vtableSlot(cp, VT_CREATE_PIPE, CreatePipeFn);
        const release_pipe = vtableSlot(cp, VT_RELEASE_PIPE, ReleasePipeFn);
        const connect_user = vtableSlot(cp, VT_CONNECT_GLOBAL_USER, ConnectUserFn);
        const release_user = vtableSlot(cp, VT_RELEASE_USER, ReleaseUserFn);
        const get_user = vtableSlot(cp, VT_GET_STEAM_USER, GetIfaceFn);
        const get_friends = vtableSlot(cp, VT_GET_STEAM_FRIENDS, GetIfaceFn);

        const pipe = create_pipe(cp);
        if (pipe <= 0) return;

        const user = connect_user(cp, pipe);
        if (user <= 0) {
            _ = release_pipe(cp, pipe);
            return;
        }

        const su = get_user(cp, user, pipe, "SteamUser023") orelse {
            release_user(cp, pipe, user);
            _ = release_pipe(cp, pipe);
            return;
        };
        const sf = get_friends(cp, user, pipe, "SteamFriends017") orelse {
            release_user(cp, pipe, user);
            _ = release_pipe(cp, pipe);
            return;
        };

        var sid: u64 = 0;
        if (builtin.os.tag == .windows) {
            const get_sid = vtableSlot(su, VT_USER_GET_STEAM_ID, GetSteamIdWinFn);
            _ = get_sid(su, &sid);
        } else {
            const get_sid = vtableSlot(su, VT_USER_GET_STEAM_ID, GetSteamIdSysvFn);
            sid = get_sid(su);
        }

        if (sid == 0) {
            release_user(cp, pipe, user);
            _ = release_pipe(cp, pipe);
            return;
        }

        self.client_ptr = cp;
        self.pipe = pipe;
        self.user = user;
        self.steam_friends = sf;
        self.steam_id = sid;
        self.connected = true;
    }
};

test "parses live EU5 English Rich Presence and dynamic country swaps" {
    const cfg_mod = @import("config.zig");
    var state = gs.GameState{};
    state.setGameVersion("1.4.9");
    const cfg = cfg_mod.Config{};

    const rp1 = parsePresenceFields(
        "Tributary under the Golden Horde as Principality of Kyiv, 1337",
        "Tributary under the Golden Horde as Principality of Kyiv, 1337",
        null,
        null,
    ).?;
    state.applySteamUpdate(&rp1);

    var d_buf: [256]u8 = undefined;
    var s_buf: [256]u8 = undefined;
    const p1 = state.formatPresence(&cfg.presence, &d_buf, &s_buf);
    try std.testing.expectEqualStrings("Playing as Principality of Kyiv (1337)", p1.details);
    try std.testing.expectEqualStrings("Tributary under the Golden Horde · Singleplayer · v1.4.9", p1.state.?);

    const rp2 = parsePresenceFields("At war against Ottomans as Byzantium, 1345 (Multiplayer)", null, null, null).?;
    state.applySteamUpdate(&rp2);
    const p2 = state.formatPresence(&cfg.presence, &d_buf, &s_buf);
    try std.testing.expectEqualStrings("Playing as Byzantium (1345)", p2.details);
    try std.testing.expectEqualStrings("At war against Ottomans · Multiplayer · v1.4.9", p2.state.?);

    const rp_lobby = parsePresenceFields("In Lobby", null, null, null).?;
    state.applySteamUpdate(&rp_lobby);
    try std.testing.expectEqual(gs.GamePhase.lobby, state.phase);

    const rp3 = parsePresenceFields("In Main Menu", null, null, null).?;
    state.applySteamUpdate(&rp3);
    try std.testing.expectEqual(gs.GamePhase.main_menu, state.phase);
    try std.testing.expectEqual(@as(?[]const u8, null), state.countryName());
}

test "parses all 10 non-English official EU5 Steam Rich Presence languages" {
    // French
    const fr = parsePresenceFields("En guerre contre l'Angleterre en tant que France, 1340 (multijoueur)", null, null, null).?;
    try std.testing.expectEqualStrings("France", fr.country().?);
    try std.testing.expectEqual(@as(?u32, 1340), fr.year);
    try std.testing.expectEqualStrings("En guerre contre l'Angleterre", fr.status().?);
    try std.testing.expectEqual(@as(?bool, true), fr.multiplayer);

    // German
    const de = parsePresenceFields("Herrscht über das Reich als Österreich, 1453 (Mehrspieler)", null, null, null).?;
    try std.testing.expectEqualStrings("Österreich", de.country().?);
    try std.testing.expectEqual(@as(?u32, 1453), de.year);
    try std.testing.expectEqual(@as(?bool, true), de.multiplayer);

    // Spanish
    const es = parsePresenceFields("En guerra contra Granada como Castilla, 1444", null, null, null).?;
    try std.testing.expectEqualStrings("Castilla", es.country().?);
    try std.testing.expectEqual(@as(?u32, 1444), es.year);
    try std.testing.expectEqualStrings("En guerra contra Granada", es.status().?);

    // Brazilian Portuguese
    const pt = parsePresenceFields("Falência como Portugal, 1500 (Multijogador)", null, null, null).?;
    try std.testing.expectEqualStrings("Portugal", pt.country().?);
    try std.testing.expectEqual(@as(?u32, 1500), pt.year);
    try std.testing.expectEqualStrings("Falência", pt.status().?);
    try std.testing.expectEqual(@as(?bool, true), pt.multiplayer);

    // Polish
    const pl = parsePresenceFields("Rządzi królestwem jako Polska, 1410 (gra wieloosobowa)", null, null, null).?;
    try std.testing.expectEqualStrings("Polska", pl.country().?);
    try std.testing.expectEqual(@as(?u32, 1410), pl.year);
    try std.testing.expectEqual(@as(?bool, true), pl.multiplayer);

    // Russian (with NBSP \u00A0 before год)
    const ru = parsePresenceFields("Банкрот за державу Московия, 1380\u{00A0}год (многопользовательская игра)", null, null, null).?;
    try std.testing.expectEqualStrings("Московия", ru.country().?);
    try std.testing.expectEqual(@as(?u32, 1380), ru.year);
    try std.testing.expectEqualStrings("Банкрот", ru.status().?);
    try std.testing.expectEqual(@as(?bool, true), ru.multiplayer);

    // Turkish
    const tr = parsePresenceFields("Osmanlı olarak Ülkeyi idare ediyor, 1453 (Çok Oyunculu)", null, null, null).?;
    try std.testing.expectEqualStrings("Osmanlı", tr.country().?);
    try std.testing.expectEqual(@as(?u32, 1453), tr.year);
    try std.testing.expectEqualStrings("Ülkeyi idare ediyor", tr.status().?);
    try std.testing.expectEqual(@as(?bool, true), tr.multiplayer);

    // Japanese
    const ja = parsePresenceFields("日本として破産、1467（マルチプレイ）", null, null, null).?;
    try std.testing.expectEqualStrings("日本", ja.country().?);
    try std.testing.expectEqual(@as(?u32, 1467), ja.year);
    try std.testing.expectEqualStrings("破産", ja.status().?);
    try std.testing.expectEqual(@as(?bool, true), ja.multiplayer);

    // Korean
    const ko = parsePresenceFields("1392, 조선(으)로 부도(멀티플레이어)", null, null, null).?;
    try std.testing.expectEqualStrings("조선", ko.country().?);
    try std.testing.expectEqual(@as(?u32, 1392), ko.year);
    try std.testing.expectEqualStrings("부도", ko.status().?);
    try std.testing.expectEqual(@as(?bool, true), ko.multiplayer);

    // Simplified Chinese
    const zh = parsePresenceFields("作为大明与元朝交战，1368年（多人游戏）", null, null, null).?;
    try std.testing.expectEqualStrings("大明", zh.country().?);
    try std.testing.expectEqual(@as(?u32, 1368), zh.year);
    try std.testing.expectEqualStrings("与元朝交战", zh.status().?);
    try std.testing.expectEqual(@as(?bool, true), zh.multiplayer);

    // Non-English Main Menu, Lobby, and Observer
    try std.testing.expectEqual(gs.GamePhase.main_menu, parsePresenceFields("メインメニュー", null, null, null).?.phase.?);
    try std.testing.expectEqual(gs.GamePhase.lobby, parsePresenceFields("В лобби", null, null, null).?.phase.?);
    const obs = parsePresenceFields("世界の行く末を観測中、1444", null, null, null).?;
    try std.testing.expectEqual(@as(?bool, true), obs.observer);
    try std.testing.expectEqual(@as(?u32, 1444), obs.year);

    // Raw token fallback
    const raw = parsePresenceFields(null, "#playing_mp", "Hungary", "1444").?;
    try std.testing.expectEqual(gs.GamePhase.in_game, raw.phase.?);
    try std.testing.expectEqualStrings("Hungary", raw.country().?);
    try std.testing.expectEqual(@as(?u32, 1444), raw.year);
    try std.testing.expectEqual(@as(?bool, true), raw.multiplayer);
}

test "cleanPdxText strips Paradox formatting codes while preserving raw presence tokens" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Kingdom of France", cleanPdxText("#V Kingdom of France#!", &buf));
    try std.testing.expectEqualStrings("#playing_mp", cleanPdxText("#playing_mp", &buf));
    try std.testing.expectEqualStrings("#main_menu", cleanPdxText("#main_menu", &buf));
}
