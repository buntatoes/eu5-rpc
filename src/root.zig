// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");

pub const toml = @import("toml.zig");
pub const config = @import("config.zig");
pub const logger = @import("logger.zig");
pub const game_state = @import("game_state.zig");
pub const country_lookup = @import("country_lookup.zig");
pub const save_inspector = @import("save_inspector.zig");
pub const eu5_files = @import("eu5_files.zig");
pub const process = @import("process.zig");
pub const steam_rp = @import("steam_rp.zig");
pub const log_watcher = @import("log_watcher.zig");
pub const discord_ipc = @import("discord_ipc.zig");

pub const VERSION = "4.0.0";
// Official public Discord detectable-application ID for Europa Universalis V (not user-specific).
pub const DEFAULT_DISCORD_APP_ID = "1435327845051400292";
pub const EU5_STEAM_APP_ID = "3450310";
pub const DEFAULT_LARGE_IMAGE_URL = "https://raw.githubusercontent.com/buntatoes/eu5-rpc/main/assets/icon.png";

pub fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype) error{NoSpaceLeft}![:0]u8 {
    if (buf.len == 0) return error.NoSpaceLeft;
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch return error.NoSpaceLeft;
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

test {
    _ = toml;
    _ = config;
    _ = logger;
    _ = game_state;
    _ = country_lookup;
    _ = save_inspector;
    _ = eu5_files;
    _ = process;
    _ = steam_rp;
    _ = log_watcher;
    _ = discord_ipc;
}
