// SPDX-License-Identifier: GPL-3.0-only
// Resolves EU5 country tags (e.g. "POR", "FRA", "BYZ") to official English country names.
// Dynamically loads all ~2,350+ countries from the user's local EU5 installation's
// localization files (country_names_l_english.yml + formable_countries_l_english.yml),
// with a built-in fallback table for common starting tags.
const std = @import("std");
const builtin = @import("builtin");
const eu5_files = @import("eu5_files.zig");
const root = @import("root.zig");

pub const FallbackTag = struct {
    tag: []const u8,
    name: []const u8,
};

pub const FALLBACK_TAGS = [_]FallbackTag{
    .{ .tag = "ARA", .name = "Aragon" },
    .{ .tag = "AUS", .name = "Austria" },
    .{ .tag = "AZT", .name = "Aztec" },
    .{ .tag = "BAV", .name = "Bavaria" },
    .{ .tag = "BOH", .name = "Bohemia" },
    .{ .tag = "BRA", .name = "Brandenburg" },
    .{ .tag = "BRB", .name = "Brabant" },
    .{ .tag = "BUL", .name = "Bulgaria" },
    .{ .tag = "BUR", .name = "Burgundy" },
    .{ .tag = "BYZ", .name = "Byzantium" },
    .{ .tag = "CAS", .name = "Castile" },
    .{ .tag = "DAN", .name = "Denmark" },
    .{ .tag = "DLH", .name = "Delhi" },
    .{ .tag = "ENG", .name = "England" },
    .{ .tag = "ETH", .name = "Ethiopia" },
    .{ .tag = "FLA", .name = "Flanders" },
    .{ .tag = "FLO", .name = "Florence" },
    .{ .tag = "FRA", .name = "France" },
    .{ .tag = "GEN", .name = "Genoa" },
    .{ .tag = "GRA", .name = "Granada" },
    .{ .tag = "HAB", .name = "Austria" },
    .{ .tag = "HOL", .name = "Holland" },
    .{ .tag = "HUN", .name = "Hungary" },
    .{ .tag = "INC", .name = "Inca" },
    .{ .tag = "IRE", .name = "Ireland" },
    .{ .tag = "JAP", .name = "Japan" },
    .{ .tag = "KIL", .name = "Kilwa" },
    .{ .tag = "KOR", .name = "Goryeo" },
    .{ .tag = "LIT", .name = "Lithuania" },
    .{ .tag = "MAM", .name = "Mamluks" },
    .{ .tag = "MLI", .name = "Mali" },
    .{ .tag = "MLO", .name = "Milan" },
    .{ .tag = "MNG", .name = "Ming" },
    .{ .tag = "MOS", .name = "Muscovy" },
    .{ .tag = "NAP", .name = "Naples" },
    .{ .tag = "NAV", .name = "Navarre" },
    .{ .tag = "NOR", .name = "Norway" },
    .{ .tag = "NOV", .name = "Novgorod" },
    .{ .tag = "PAP", .name = "Papal States" },
    .{ .tag = "POL", .name = "Poland" },
    .{ .tag = "POR", .name = "Portugal" },
    .{ .tag = "PRU", .name = "Prussia" },
    .{ .tag = "RUS", .name = "Russia" },
    .{ .tag = "SAV", .name = "Savoy" },
    .{ .tag = "SAX", .name = "Saxony" },
    .{ .tag = "SCO", .name = "Scotland" },
    .{ .tag = "SER", .name = "Serbia" },
    .{ .tag = "SPA", .name = "Spain" },
    .{ .tag = "SWE", .name = "Sweden" },
    .{ .tag = "TEU", .name = "Teutonic Order" },
    .{ .tag = "TUR", .name = "Ottomans" },
    .{ .tag = "VEN", .name = "Venice" },
    .{ .tag = "VIJ", .name = "Vijayanagar" },
    .{ .tag = "YUA", .name = "Yuan" },
};

pub fn lookupFallbackTag(upper_tag: []const u8) ?[]const u8 {
    for (FALLBACK_TAGS) |entry| {
        if (std.mem.eql(u8, entry.tag, upper_tag)) return entry.name;
    }
    return null;
}

fn isTagChar(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
}

pub const CountryLookup = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged([]const u8),

    pub fn init(backing: std.mem.Allocator) CountryLookup {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .map = .{},
        };
    }

    pub fn deinit(self: *CountryLookup) void {
        self.arena.deinit();
    }

    pub fn loadFromGameDir(self: *CountryLookup, game_dir: []const u8) usize {
        if (game_dir.len == 0) return 0;
        const sep = if (builtin.os.tag == .windows) "\\" else "/";
        const files = [_][]const u8{
            "country_names_l_english.yml",
            "formable_countries_l_english.yml",
        };
        var loaded: usize = 0;
        var path_buf: [768]u8 = undefined;
        for (files) |fname| {
            const p = root.bufPrintZ(
                &path_buf,
                "{s}{s}game{s}main_menu{s}localization{s}english{s}{s}",
                .{ game_dir, sep, sep, sep, sep, sep, fname },
            ) catch continue;
            loaded += self.loadLocalizationFile(p.ptr);
        }
        return loaded;
    }

    pub fn loadLocalizationFile(self: *CountryLookup, path_z: [*:0]const u8) usize {
        const backing = self.arena.child_allocator;
        const raw = eu5_files.readFileAlloc(backing, path_z, 32 * 1024 * 1024) orelse return 0;
        defer backing.free(raw);
        return self.parseLocalizationContent(raw);
    }

    /// Parses Paradox localization lines matching `^\s+([A-Z0-9_]{2,24}):\d*\s+"([^"]+)"`.
    pub fn parseLocalizationContent(self: *CountryLookup, content: []const u8) usize {
        const alloc = self.arena.allocator();
        var count: usize = 0;

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0 or (line[0] != ' ' and line[0] != '\t')) continue;

            var i: usize = 0;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
            const tag_start = i;
            while (i < line.len and isTagChar(line[i])) : (i += 1) {}
            const tag = line[tag_start..i];
            if (tag.len < 2 or tag.len > 24) continue;

            if (i >= line.len or line[i] != ':') continue;
            i += 1;
            while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
            const ws_start = i;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
            if (i == ws_start or i >= line.len or line[i] != '"') continue;

            const name_start = i + 1;
            const quote_rel = std.mem.indexOfScalar(u8, line[name_start..], '"') orelse continue;
            const name = std.mem.trim(u8, line[name_start .. name_start + quote_rel], " \t");
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '$') != null) continue;

            const k = alloc.dupe(u8, tag) catch continue;
            const v = alloc.dupe(u8, name) catch continue;
            self.map.put(alloc, k, v) catch continue;
            count += 1;
        }
        return count;
    }

    /// Resolves `tag` to its localized name, built-in fallback name, or uppercased tag (stored in `upper_buf`).
    /// Returns `null` for empty, "NO", or "NONE".
    pub fn resolve(self: *const CountryLookup, raw_tag: []const u8, upper_buf: []u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, raw_tag, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > upper_buf.len) return null;

        for (trimmed, 0..) |ch, idx| {
            upper_buf[idx] = std.ascii.toUpper(ch);
        }
        const key = upper_buf[0..trimmed.len];
        if (std.mem.eql(u8, key, "NO") or std.mem.eql(u8, key, "NONE")) return null;

        if (self.map.get(key)) |name| return name;
        if (lookupFallbackTag(key)) |name| return name;
        return key;
    }
};

test "resolves localized, fallback, and unknown country tags" {
    var lookup = CountryLookup.init(std.testing.allocator);
    defer lookup.deinit();

    const sample =
        "l_english:\n" ++
        " POR: \"Portugal\"\n" ++
        " CUSTOM:0 \"Custom Empire\"\n" ++
        " DYN_TAG: \"$DYNAMIC$\"\n";
    const loaded = lookup.parseLocalizationContent(sample);
    try std.testing.expectEqual(@as(usize, 2), loaded);

    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Portugal", lookup.resolve("por", &buf).?);
    try std.testing.expectEqualStrings("Custom Empire", lookup.resolve("CUSTOM", &buf).?);
    try std.testing.expectEqualStrings("Byzantium", lookup.resolve("BYZ", &buf).?);
    try std.testing.expectEqualStrings("ZZZ", lookup.resolve("zzz", &buf).?);
    try std.testing.expectEqual(@as(?[]const u8, null), lookup.resolve("No", &buf));
    try std.testing.expectEqual(@as(?[]const u8, null), lookup.resolve("None", &buf));
}
