// SPDX-License-Identifier: GPL-3.0-only
// Parses EU5 save metadata from continue_game.json and .eu5 save headers/filenames
// without ever modifying saves or reading game memory. Full Unicode support on Windows & Linux.
const std = @import("std");
const builtin = @import("builtin");
const eu5_files = @import("eu5_files.zig");
const root = @import("root.zig");

const win = if (builtin.os.tag == .windows) struct {
    const HANDLE = ?*anyopaque;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
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
    extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
    extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) i32;
    extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.winapi) i32;
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
    extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
    extern "c" fn readdir(dirp: *DIR) ?*Dirent;
    extern "c" fn closedir(dirp: *DIR) c_int;
} else struct {};

pub const SaveMetadata = struct {
    country_name_buf: [128]u8 = undefined,
    country_name_len: usize = 0,
    country_tag_buf: [16]u8 = undefined,
    country_tag_len: usize = 0,
    year: ?u32 = null,
    date_buf: [32]u8 = undefined,
    date_len: usize = 0,
    multiplayer: ?bool = null,
    game_version_buf: [32]u8 = undefined,
    game_version_len: usize = 0,

    pub fn countryName(self: *const SaveMetadata) ?[]const u8 {
        return if (self.country_name_len > 0) self.country_name_buf[0..self.country_name_len] else null;
    }

    pub fn countryTag(self: *const SaveMetadata) ?[]const u8 {
        return if (self.country_tag_len > 0) self.country_tag_buf[0..self.country_tag_len] else null;
    }

    pub fn dateStr(self: *const SaveMetadata) ?[]const u8 {
        return if (self.date_len > 0) self.date_buf[0..self.date_len] else null;
    }

    pub fn gameVersion(self: *const SaveMetadata) ?[]const u8 {
        return if (self.game_version_len > 0) self.game_version_buf[0..self.game_version_len] else null;
    }

    pub fn setCountryName(self: *SaveMetadata, s: []const u8) void {
        const n = @min(s.len, self.country_name_buf.len);
        @memcpy(self.country_name_buf[0..n], s[0..n]);
        self.country_name_len = n;
    }

    pub fn setCountryTag(self: *SaveMetadata, s: []const u8) void {
        const n = @min(s.len, self.country_tag_buf.len);
        for (s[0..n], 0..) |ch, i| self.country_tag_buf[i] = std.ascii.toUpper(ch);
        self.country_tag_len = n;
    }

    pub fn setDateStr(self: *SaveMetadata, s: []const u8) void {
        const n = @min(s.len, self.date_buf.len);
        @memcpy(self.date_buf[0..n], s[0..n]);
        self.date_len = n;
    }

    pub fn setGameVersion(self: *SaveMetadata, s: []const u8) void {
        const n = @min(s.len, self.game_version_buf.len);
        @memcpy(self.game_version_buf[0..n], s[0..n]);
        self.game_version_len = n;
    }
};

/// Lightweight zero-allocation JSON string field extractor (e.g. `"rawGameVersion":"1.4.7"`).
pub fn extractJsonStringField(json: []const u8, key: []const u8, out_buf: []u8) ?[]const u8 {
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        if (json[i] != '"') continue;
        const k_start = i + 1;
        if (k_start + key.len >= json.len) break;
        if (std.mem.eql(u8, json[k_start .. k_start + key.len], key) and json[k_start + key.len] == '"') {
            var j = k_start + key.len + 1;
            while (j < json.len and (json[j] == ' ' or json[j] == '\t' or json[j] == '\r' or json[j] == '\n')) : (j += 1) {}
            if (j >= json.len or json[j] != ':') continue;
            j += 1;
            while (j < json.len and (json[j] == ' ' or json[j] == '\t' or json[j] == '\r' or json[j] == '\n')) : (j += 1) {}
            if (j >= json.len or json[j] != '"') continue;
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
                    const trimmed = std.mem.trim(u8, out_buf[0..out_len], " \t\r\n");
                    return if (trimmed.len > 0) trimmed else null;
                }
                if (out_len < out_buf.len) {
                    out_buf[out_len] = json[j];
                    out_len += 1;
                }
            }
        }
    }
    return null;
}

pub fn readContinueGameField(user_data_dir: []const u8, key: []const u8, out_buf: []u8) ?[]const u8 {
    const sep = if (builtin.os.tag == .windows) "\\" else "/";
    var path_buf: [768]u8 = undefined;
    const p = root.bufPrintZ(&path_buf, "{s}{s}continue_game.json", .{ user_data_dir, sep }) catch return null;

    var raw: [8192]u8 = undefined;
    const n = eu5_files.readFileRange(p.ptr, 0, &raw) orelse return null;
    if (n == 0) return null;
    return extractJsonStringField(raw[0..n], key, out_buf);
}

fn endsWithEu5(name: []const u8) bool {
    return name.len >= 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".eu5");
}

pub const NewestSave = struct {
    path: []const u8,
    mtime: i64,
};

pub fn findNewestSave(saves_dir: []const u8, out_buf: []u8) ?NewestSave {
    const sep = if (builtin.os.tag == .windows) "\\" else "/";
    var best_path_buf: [768]u8 = undefined;
    var best_len: usize = 0;
    var best_mtime: i64 = -1;

    if (builtin.os.tag == .windows) {
        var pat_buf: [768]u8 = undefined;
        const pat = root.bufPrintZ(&pat_buf, "{s}\\*.eu5", .{saves_dir}) catch return null;
        var pat_w: [1024]u16 = undefined;
        const pw = eu5_files.utf8ToUtf16Z(pat, &pat_w) orelse return null;

        var fd: win.WIN32_FIND_DATAW = undefined;
        const h = win.FindFirstFileW(pw.ptr, &fd);
        if (h == win.INVALID_HANDLE_VALUE) return null;
        defer _ = win.FindClose(h);

        while (true) {
            if ((fd.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY) == 0) {
                const wlen = eu5_files.utf16Len(@ptrCast(&fd.cFileName));
                var name_u8: [512]u8 = undefined;
                if (eu5_files.utf16ToUtf8(fd.cFileName[0..wlen], &name_u8)) |name| {
                    if (endsWithEu5(name)) {
                        var cand_buf: [768]u8 = undefined;
                        if (root.bufPrintZ(&cand_buf, "{s}\\{s}", .{ saves_dir, name })) |cand| {
                            const ticks: u64 = (@as(u64, fd.ftLastWriteTime.dwHighDateTime) << 32) | fd.ftLastWriteTime.dwLowDateTime;
                            const mtime: i64 = @as(i64, @intCast(ticks / 10_000_000)) - 11_644_473_600;
                            if (best_len == 0 or mtime > best_mtime) {
                                @memcpy(best_path_buf[0..cand.len], cand);
                                best_path_buf[cand.len] = 0;
                                best_len = cand.len;
                                best_mtime = mtime;
                            }
                        } else |_| {}
                    }
                }
            }
            if (win.FindNextFileW(h, &fd) == 0) break;
        }
    } else {
        var dir_z_buf: [768]u8 = undefined;
        const dir_z = root.bufPrintZ(&dir_z_buf, "{s}", .{saves_dir}) catch return null;
        const d = posix.opendir(dir_z.ptr) orelse return null;
        defer _ = posix.closedir(d);

        while (posix.readdir(d)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.d_name)));
            if (!endsWithEu5(name)) continue;

            var cand_buf: [768]u8 = undefined;
            const cand = root.bufPrintZ(&cand_buf, "{s}{s}{s}", .{ saves_dir, sep, name }) catch continue;
            if (!eu5_files.fileExists(cand.ptr)) continue;
            const mtime = eu5_files.fileMtime(cand.ptr) orelse 0;
            if (best_len == 0 or mtime > best_mtime) {
                @memcpy(best_path_buf[0..cand.len], cand);
                best_path_buf[cand.len] = 0;
                best_len = cand.len;
                best_mtime = mtime;
            }
        }
    }

    if (best_len == 0 or best_len >= out_buf.len) return null;
    @memcpy(out_buf[0..best_len], best_path_buf[0..best_len]);
    out_buf[best_len] = 0;
    return .{
        .path = out_buf[0..best_len],
        .mtime = best_mtime,
    };
}

fn isUpperAlnum(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
}

fn isAlphaNum(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9');
}

fn isWordChar(ch: u8) bool {
    return isAlphaNum(ch) or ch == '_';
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isHexDigit(ch: u8) bool {
    return isDigit(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

/// Parses EU5 save filename pattern `^(SP|MP)_([A-Z0-9]{2,5})_(\d{3,4})_(\d{2})_(\d{2})_` (case-insensitive).
pub fn parseFilename(basename: []const u8) SaveMetadata {
    var meta = SaveMetadata{};
    if (basename.len < 16) return meta;

    const is_sp = std.ascii.eqlIgnoreCase(basename[0..3], "SP_");
    const is_mp = std.ascii.eqlIgnoreCase(basename[0..3], "MP_");
    if (!is_sp and !is_mp) return meta;

    var i: usize = 3;
    const tag_start = i;
    while (i < basename.len and isAlphaNum(basename[i])) : (i += 1) {}
    const tag = basename[tag_start..i];
    if (tag.len < 2 or tag.len > 5) return meta;
    if (i >= basename.len or basename[i] != '_') return meta;
    i += 1;

    const yr_start = i;
    while (i < basename.len and isDigit(basename[i])) : (i += 1) {}
    const yr_s = basename[yr_start..i];
    if (yr_s.len < 3 or yr_s.len > 4) return meta;
    if (i >= basename.len or basename[i] != '_') return meta;
    i += 1;

    if (i + 5 >= basename.len) return meta;
    const mo_s = basename[i .. i + 2];
    if (!isDigit(mo_s[0]) or !isDigit(mo_s[1]) or basename[i + 2] != '_') return meta;
    const dy_s = basename[i + 3 .. i + 5];
    if (!isDigit(dy_s[0]) or !isDigit(dy_s[1]) or basename[i + 5] != '_') return meta;

    const yr = std.fmt.parseInt(u32, yr_s, 10) catch return meta;
    const mo = std.fmt.parseInt(u32, mo_s, 10) catch return meta;
    const dy = std.fmt.parseInt(u32, dy_s, 10) catch return meta;

    meta.multiplayer = is_mp;
    meta.setCountryTag(tag);
    meta.year = yr;
    var dbuf: [32]u8 = undefined;
    if (std.fmt.bufPrint(&dbuf, "{d}.{d}.{d}", .{ yr, mo, dy })) |ds| {
        meta.setDateStr(ds);
    } else |_| {}
    return meta;
}

fn parseDottedNumbers(data: []const u8, start: usize, min_first: usize, max_first: usize) ?struct { end: usize, first: u32 } {
    var i = start;
    const f_start = i;
    while (i < data.len and isDigit(data[i])) : (i += 1) {}
    const f_len = i - f_start;
    if (f_len < min_first or f_len > max_first) return null;
    if (i >= data.len or data[i] != '.') return null;
    i += 1;

    const s_start = i;
    while (i < data.len and isDigit(data[i])) : (i += 1) {}
    const s_len = i - s_start;
    if (s_len < 1 or s_len > 2) return null;
    if (i >= data.len or data[i] != '.') return null;
    i += 1;

    const t_start = i;
    while (i < data.len and isDigit(data[i])) : (i += 1) {}
    const t_len = i - t_start;
    if (t_len < 1 or t_len > 2) return null;

    const first = std.fmt.parseInt(u32, data[f_start .. f_start + f_len], 10) catch return null;
    return .{ .end = i, .first = first };
}

fn stripTrailingHexHash(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    const hash_idx = std.mem.lastIndexOfScalar(u8, trimmed, '#') orelse return trimmed;
    if (hash_idx == 0 or hash_idx + 1 >= trimmed.len) return trimmed;
    if (trimmed[hash_idx - 1] != ' ' and trimmed[hash_idx - 1] != '\t') return trimmed;
    for (trimmed[hash_idx + 1 ..]) |ch| {
        if (!isHexDigit(ch)) return trimmed;
    }
    return std.mem.trimEnd(u8, trimmed[0..hash_idx], " \t");
}

/// Scans the first 2 KiB of a `.eu5` save header for date, country name, country tag, and version.
pub fn mergeHeader(meta: *SaveMetadata, raw: []const u8) void {
    // 1. HEADER_DATE_COUNTRY_RE: (\d{3,4}\.\d{1,2}\.\d{1,2})\s+-\s+([^\x00-\x1f\r\n]{2,64})
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (!isDigit(raw[i])) continue;
        if (i > 0 and isDigit(raw[i - 1])) continue;
        if (parseDottedNumbers(raw, i, 3, 4)) |d| {
            var j = d.end;
            const ws1 = j;
            while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) : (j += 1) {}
            if (j > ws1 and j < raw.len and raw[j] == '-') {
                j += 1;
                const ws2 = j;
                while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) : (j += 1) {}
                if (j > ws2) {
                    const c_start = j;
                    while (j < raw.len and j - c_start < 64 and raw[j] >= 0x20) : (j += 1) {}
                    if (j - c_start >= 2) {
                        meta.setDateStr(raw[i..d.end]);
                        meta.year = d.first;
                        const country = stripTrailingHexHash(raw[c_start..j]);
                        if (country.len > 0) meta.setCountryName(country);
                        break;
                    }
                }
            }
        }
    }

    // 2. HEADER_TAG_RE: \b([A-Z0-9]{3})=\{
    if (meta.countryTag() == null) {
        i = 0;
        while (i + 5 <= raw.len) : (i += 1) {
            if (i > 0 and isWordChar(raw[i - 1])) continue;
            if (isUpperAlnum(raw[i]) and isUpperAlnum(raw[i + 1]) and isUpperAlnum(raw[i + 2]) and
                raw[i + 3] == '=' and raw[i + 4] == '{')
            {
                meta.setCountryTag(raw[i .. i + 3]);
                break;
            }
        }
    }

    // 3. HEADER_VERSION_RE: \b(\d{1,2}\.\d{1,2}\.\d{1,2})\b
    if (meta.gameVersion() == null) {
        i = 0;
        while (i < raw.len) : (i += 1) {
            if (!isDigit(raw[i])) continue;
            if (i > 0 and isWordChar(raw[i - 1])) continue;
            if (parseDottedNumbers(raw, i, 1, 2)) |v| {
                if (v.end == raw.len or !isWordChar(raw[v.end])) {
                    meta.setGameVersion(raw[i..v.end]);
                    break;
                }
            }
        }
    }
}

pub fn parseSaveFile(path_z: [*:0]const u8) SaveMetadata {
    const path = std.mem.span(path_z);
    var base_start: usize = 0;
    for (path, 0..) |ch, idx| {
        if (ch == '/' or ch == '\\') base_start = idx + 1;
    }
    var meta = parseFilename(path[base_start..]);
    var header: [2048]u8 = undefined;
    const n = eu5_files.readFileRange(path_z, 0, &header) orelse return meta;
    if (n > 0) mergeHeader(&meta, header[0..n]);
    return meta;
}

pub fn inspectUserDataDir(user_data_dir: []const u8) ?SaveMetadata {
    if (user_data_dir.len == 0) return null;
    const sep = if (builtin.os.tag == .windows) "\\" else "/";

    var ver_buf: [64]u8 = undefined;
    const version = readContinueGameField(user_data_dir, "rawGameVersion", &ver_buf);

    var title_buf: [256]u8 = undefined;
    const continue_title = readContinueGameField(user_data_dir, "title", &title_buf);

    var saves_dir_buf: [768]u8 = undefined;
    const saves_dir = root.bufPrintZ(&saves_dir_buf, "{s}{s}save games", .{ user_data_dir, sep }) catch return null;

    var newest_buf: [768]u8 = undefined;
    var target_save: ?[:0]const u8 = null;
    var target_buf: [768]u8 = undefined;

    if (findNewestSave(saves_dir, &newest_buf)) |ns| {
        target_save = root.bufPrintZ(&target_buf, "{s}", .{ns.path}) catch null;
    } else if (continue_title) |title| {
        if (root.bufPrintZ(&target_buf, "{s}{s}{s}.eu5", .{ saves_dir, sep, title })) |cand| {
            if (eu5_files.fileExists(cand.ptr)) target_save = cand;
        } else |_| {}
    }

    if (target_save) |save_path| {
        var meta = parseSaveFile(save_path.ptr);
        if (meta.gameVersion() == null) {
            if (version) |v| meta.setGameVersion(v);
        }
        return meta;
    }

    if (continue_title) |title| {
        var fake_name_buf: [280]u8 = undefined;
        const fake_name = std.fmt.bufPrint(&fake_name_buf, "{s}.eu5", .{title}) catch title;
        var meta = parseFilename(fake_name);
        if (meta.gameVersion() == null) {
            if (version) |v| meta.setGameVersion(v);
        }
        return meta;
    }

    if (version) |v| {
        var meta = SaveMetadata{};
        meta.setGameVersion(v);
        return meta;
    }
    return null;
}

test "parses EU5 save filename and binary header metadata" {
    const filename = "SP_FRA_1453_05_29_00000000-0000-0000-0000-000000000000.eu5";
    var meta = parseFilename(filename);
    try std.testing.expectEqual(@as(?bool, false), meta.multiplayer);
    try std.testing.expectEqualStrings("FRA", meta.countryTag().?);
    try std.testing.expectEqual(@as(?u32, 1453), meta.year);
    try std.testing.expectEqualStrings("1453.5.29", meta.dateStr().?);

    const header = "SAV0303\x00\x011453.5.29 - France #112233\x001.4.7\x00FRA={\n}\n";
    mergeHeader(&meta, header);
    try std.testing.expectEqualStrings("France", meta.countryName().?);
    try std.testing.expectEqualStrings("FRA", meta.countryTag().?);
    try std.testing.expectEqual(@as(?u32, 1453), meta.year);
    try std.testing.expectEqualStrings("1453.5.29", meta.dateStr().?);
    try std.testing.expectEqualStrings("1.4.7", meta.gameVersion().?);
}

test "inspectUserDataDir reads continue_game.json and newest .eu5 save on Linux and Windows" {
    const sep = if (builtin.os.tag == .windows) "\\" else "/";
    var temp_root_buf: [512]u8 = undefined;
    const temp_root = if (builtin.os.tag == .windows)
        eu5_files.getEnvUtf8("TEMP", &temp_root_buf) orelse "."
    else
        "/tmp";

    var dir_buf: [600]u8 = undefined;
    const dir = root.bufPrintZ(&dir_buf, "{s}{s}eu5-rpc-test-save", .{ temp_root, sep }) catch unreachable;
    var saves_buf: [640]u8 = undefined;
    const saves = root.bufPrintZ(&saves_buf, "{s}{s}save games", .{ dir, sep }) catch unreachable;
    eu5_files.ensureDirRecursive(saves);

    var cont_buf: [640]u8 = undefined;
    const cont_path = root.bufPrintZ(&cont_buf, "{s}{s}continue_game.json", .{ dir, sep }) catch unreachable;
    try std.testing.expect(eu5_files.writeFileAll(cont_path.ptr, "{\"rawGameVersion\":\"1.4.7\"}"));

    var save_buf: [700]u8 = undefined;
    const save_path = root.bufPrintZ(&save_buf, "{s}{s}SP_FRA_1453_05_29_00000000-0000-0000-0000-000000000000.eu5", .{ saves, sep }) catch unreachable;
    try std.testing.expect(eu5_files.writeFileAll(save_path.ptr, "SAV0303\x00\x011453.5.29 - France #112233\x001.4.7\x00FRA={\n}\n"));

    const meta = inspectUserDataDir(dir).?;
    try std.testing.expectEqualStrings("France", meta.countryName().?);
    try std.testing.expectEqualStrings("FRA", meta.countryTag().?);
    try std.testing.expectEqual(@as(?u32, 1453), meta.year);
    try std.testing.expectEqualStrings("1453.5.29", meta.dateStr().?);
    try std.testing.expectEqual(@as(?bool, false), meta.multiplayer);
    try std.testing.expectEqualStrings("1.4.7", meta.gameVersion().?);
}
