// SPDX-License-Identifier: GPL-3.0-only
// Lightweight zero-dependency TOML parser and serializer for eu5-rpc config.toml.
const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
};

pub const Entry = struct {
    section: []const u8, // "" for root, "general", "presence.status", etc.
    key: []const u8,
    value: Value,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry),

    pub fn init(backing: std.mem.Allocator) Document {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    pub fn set(self: *Document, section: []const u8, key: []const u8, value: Value) !void {
        const alloc = self.arena.allocator();
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.section, section) and std.mem.eql(u8, e.key, key)) {
                e.value = switch (value) {
                    .string => |s| .{ .string = try alloc.dupe(u8, s) },
                    else => value,
                };
                return;
            }
        }
        const dup_val: Value = switch (value) {
            .string => |s| .{ .string = try alloc.dupe(u8, s) },
            else => value,
        };
        try self.entries.append(alloc, .{
            .section = try alloc.dupe(u8, section),
            .key = try alloc.dupe(u8, key),
            .value = dup_val,
        });
    }

    pub fn get(self: *const Document, section: []const u8, key: []const u8) ?Value {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.section, section) and std.mem.eql(u8, e.key, key)) {
                return e.value;
            }
        }
        return null;
    }

    pub fn getString(self: *const Document, section: []const u8, key: []const u8) ?[]const u8 {
        const val = self.get(section, key) orelse return null;
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getBool(self: *const Document, section: []const u8, key: []const u8) ?bool {
        const val = self.get(section, key) orelse return null;
        return switch (val) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn getInt(self: *const Document, section: []const u8, key: []const u8) ?i64 {
        const val = self.get(section, key) orelse return null;
        return switch (val) {
            .integer => |n| n,
            else => null,
        };
    }
};

pub fn stripComment(line: []const u8) []const u8 {
    var in_double = false;
    var in_single = false;
    var escaped = false;

    for (line, 0..) |ch, idx| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\' and in_double) {
            escaped = true;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
        } else if (ch == '\'' and !in_double) {
            in_single = !in_single;
        } else if (ch == '#' and !in_double and !in_single) {
            return line[0..idx];
        }
    }
    return line;
}

fn unescapeDoubleQuoted(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const next = raw[i + 1];
            switch (next) {
                '"' => {
                    try out.append(alloc, '"');
                    i += 1;
                    continue;
                },
                '\\' => {
                    try out.append(alloc, '\\');
                    i += 1;
                    continue;
                },
                'n' => {
                    try out.append(alloc, '\n');
                    i += 1;
                    continue;
                },
                't' => {
                    try out.append(alloc, '\t');
                    i += 1;
                    continue;
                },
                'r' => {
                    try out.append(alloc, '\r');
                    i += 1;
                    continue;
                },
                else => {},
            }
        }
        try out.append(alloc, raw[i]);
    }
    return out.toOwnedSlice(alloc);
}

fn parseValue(alloc: std.mem.Allocator, val_str: []const u8) !Value {
    if (val_str.len >= 2 and val_str[0] == '"' and val_str[val_str.len - 1] == '"') {
        const unescaped = try unescapeDoubleQuoted(alloc, val_str[1 .. val_str.len - 1]);
        return .{ .string = unescaped };
    }
    if (val_str.len >= 2 and val_str[0] == '\'' and val_str[val_str.len - 1] == '\'') {
        return .{ .string = try alloc.dupe(u8, val_str[1 .. val_str.len - 1]) };
    }
    if (std.mem.eql(u8, val_str, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, val_str, "false")) return .{ .boolean = false };
    if (isSignedInteger(val_str)) {
        if (std.fmt.parseInt(i64, val_str, 10)) |n| {
            return .{ .integer = n };
        } else |_| {}
    }
    return .{ .string = try alloc.dupe(u8, val_str) };
}

fn isSignedInteger(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '-') {
        if (s.len == 1) return false;
        i = 1;
    }
    while (i < s.len) : (i += 1) {
        if (s[i] < '0' or s[i] > '9') return false;
    }
    return true;
}

pub fn parse(backing: std.mem.Allocator, text: []const u8) !Document {
    var doc = Document.init(backing);
    errdefer doc.deinit();

    const alloc = doc.arena.allocator();
    var current_section: []const u8 = "";

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const stripped = std.mem.trim(u8, stripComment(raw_line), " \t\r");
        if (stripped.len == 0) continue;

        if (stripped.len >= 2 and stripped[0] == '[' and stripped[stripped.len - 1] == ']') {
            const inner = std.mem.trim(u8, stripped[1 .. stripped.len - 1], " \t");
            current_section = try alloc.dupe(u8, inner);
        } else if (std.mem.indexOfScalar(u8, stripped, '=')) |eq_idx| {
            const key = std.mem.trim(u8, stripped[0..eq_idx], " \t");
            const val_str = std.mem.trim(u8, stripped[eq_idx + 1 ..], " \t");
            if (key.len > 0) {
                const val = try parseValue(alloc, val_str);
                try doc.set(current_section, key, val);
            }
        }
    }

    return doc;
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn appendFormattedValue(out: *std.ArrayList(u8), alloc: std.mem.Allocator, val: Value) !void {
    switch (val) {
        .boolean => |b| try out.appendSlice(alloc, if (b) "true" else "false"),
        .integer => |n| {
            var num_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch unreachable;
            try out.appendSlice(alloc, s);
        },
        .string => |s| {
            if (std.mem.indexOfScalar(u8, s, '\\') != null and std.mem.indexOfScalar(u8, s, '\'') == null and std.mem.indexOfScalar(u8, s, '\n') == null) {
                try out.append(alloc, '\'');
                try out.appendSlice(alloc, s);
                try out.append(alloc, '\'');
            } else {
                try out.append(alloc, '"');
                for (s) |ch| {
                    switch (ch) {
                        '\\' => try out.appendSlice(alloc, "\\\\"),
                        '"' => try out.appendSlice(alloc, "\\\""),
                        '\n' => try out.appendSlice(alloc, "\\n"),
                        '\r' => try out.appendSlice(alloc, "\\r"),
                        '\t' => try out.appendSlice(alloc, "\\t"),
                        else => try out.append(alloc, ch),
                    }
                }
                try out.append(alloc, '"');
            }
        },
    }
}

pub fn dump(alloc: std.mem.Allocator, doc: *const Document) ![]u8 {
    var sections = std.ArrayList([]const u8).empty;
    defer sections.deinit(alloc);

    for (doc.entries.items) |e| {
        var found = false;
        for (sections.items) |sec| {
            if (std.mem.eql(u8, sec, e.section)) {
                found = true;
                break;
            }
        }
        if (!found) try sections.append(alloc, e.section);
    }
    std.mem.sort([]const u8, sections.items, {}, strLessThan);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    for (sections.items) |sec| {
        if (out.items.len > 0) try out.append(alloc, '\n');
        if (sec.len > 0) {
            try out.append(alloc, '[');
            try out.appendSlice(alloc, sec);
            try out.appendSlice(alloc, "]\n");
        }

        var keys = std.ArrayList([]const u8).empty;
        defer keys.deinit(alloc);

        for (doc.entries.items) |e| {
            if (std.mem.eql(u8, e.section, sec)) {
                try keys.append(alloc, e.key);
            }
        }
        std.mem.sort([]const u8, keys.items, {}, strLessThan);

        for (keys.items) |k| {
            const val = doc.get(sec, k).?;
            try out.appendSlice(alloc, k);
            try out.appendSlice(alloc, " = ");
            try appendFormattedValue(&out, alloc, val);
            try out.append(alloc, '\n');
        }
    }

    return out.toOwnedSlice(alloc);
}

test "parses and roundtrips TOML sections, comments, escapes, booleans, and integers" {
    const sample =
        "# comment line\n" ++
        "[general]\n" ++
        "launch_game_on_start = true # inline comment\n" ++
        "poll_interval_ms = 1000\n" ++
        "user_data_folder = 'Documents\\Paradox Interactive\\Europa Universalis V'\n" ++
        "\n" ++
        "[presence.status]\n" ++
        "in_game_with_country = \"Playing as {country} ({year})\"\n";

    var doc = try parse(std.testing.allocator, sample);
    defer doc.deinit();

    try std.testing.expectEqual(@as(?bool, true), doc.getBool("general", "launch_game_on_start"));
    try std.testing.expectEqual(@as(?i64, 1000), doc.getInt("general", "poll_interval_ms"));
    try std.testing.expectEqualStrings("Documents\\Paradox Interactive\\Europa Universalis V", doc.getString("general", "user_data_folder").?);
    try std.testing.expectEqualStrings("Playing as {country} ({year})", doc.getString("presence.status", "in_game_with_country").?);

    const dumped = try dump(std.testing.allocator, &doc);
    defer std.testing.allocator.free(dumped);

    var doc2 = try parse(std.testing.allocator, dumped);
    defer doc2.deinit();

    try std.testing.expectEqual(@as(?bool, true), doc2.getBool("general", "launch_game_on_start"));
    try std.testing.expectEqual(@as(?i64, 1000), doc2.getInt("general", "poll_interval_ms"));
    try std.testing.expectEqualStrings("Documents\\Paradox Interactive\\Europa Universalis V", doc2.getString("general", "user_data_folder").?);
    try std.testing.expectEqualStrings("Playing as {country} ({year})", doc2.getString("presence.status", "in_game_with_country").?);
}
