// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const builtin = @import("builtin");
const eu5_files = @import("eu5_files.zig");
const root = @import("root.zig");

const FILE = anyopaque;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fflush(stream: *FILE) c_int;
extern "c" fn fclose(stream: *FILE) c_int;
extern "c" fn time(tloc: ?*i64) i64;
extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;

const win = if (builtin.os.tag == .windows) struct {
    const HANDLE = ?*anyopaque;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const GENERIC_WRITE: u32 = 0x40000000;
    const FILE_SHARE_READ: u32 = 0x00000001;
    const CREATE_ALWAYS: u32 = 2;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: HANDLE,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
} else struct {};

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

pub const Logger = struct {
    level: Level = .info,
    posix_file: if (builtin.os.tag != .windows) ?*FILE else void = if (builtin.os.tag != .windows) null else {},
    win_handle: if (builtin.os.tag == .windows) win.HANDLE else void = if (builtin.os.tag == .windows) win.INVALID_HANDLE_VALUE else {},
    log_to_stdout: bool = (builtin.os.tag != .windows or builtin.mode == .debug),

    pub fn init(self: *Logger, base_dir: []const u8) void {
        const sep = if (builtin.os.tag == .windows) "\\" else "/";
        var logs_dir_buf: [600]u8 = undefined;
        const logs_dir = root.bufPrintZ(&logs_dir_buf, "{s}{s}logs", .{ base_dir, sep }) catch return;
        eu5_files.ensureDirRecursive(logs_dir);

        var path_buf: [640]u8 = undefined;
        const log_path = root.bufPrintZ(&path_buf, "{s}{s}eu5-rpc.log", .{ logs_dir, sep }) catch return;

        if (builtin.os.tag == .windows) {
            var wbuf: [1024]u16 = undefined;
            if (eu5_files.utf8ToUtf16Z(log_path, &wbuf)) |w| {
                self.win_handle = win.CreateFileW(
                    w.ptr,
                    win.GENERIC_WRITE,
                    win.FILE_SHARE_READ,
                    null,
                    win.CREATE_ALWAYS,
                    win.FILE_ATTRIBUTE_NORMAL,
                    null,
                );
            }
        } else {
            self.posix_file = fopen(log_path.ptr, "wb");
        }
        self.info("eu5-rpc started", .{});
    }

    pub fn close(self: *Logger) void {
        if (builtin.os.tag == .windows) {
            if (self.win_handle != win.INVALID_HANDLE_VALUE) {
                _ = win.CloseHandle(self.win_handle);
                self.win_handle = win.INVALID_HANDLE_VALUE;
            }
        } else {
            if (self.posix_file) |fp| {
                _ = fclose(fp);
                self.posix_file = null;
            }
        }
    }

    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.write(.debug, fmt, args);
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.write(.info, fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.write(.warn, fmt, args);
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.write(.err, fmt, args);
    }

    fn write(self: *Logger, lvl: Level, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(lvl) < @intFromEnum(self.level)) return;

        var ts_buf: [32]u8 = undefined;
        const ts = formatUtcTimestamp(&ts_buf, time(null));

        var msg_buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;

        var line_buf: [1152]u8 = undefined;
        const line = root.bufPrintZ(&line_buf, "{s} [{s}] {s}\n", .{ ts, lvl.label(), msg }) catch return;

        if (self.log_to_stdout) {
            _ = printf("%s", line.ptr);
        }
        if (builtin.os.tag == .windows) {
            if (self.win_handle != win.INVALID_HANDLE_VALUE) {
                var written: u32 = 0;
                _ = win.WriteFile(self.win_handle, line.ptr, @intCast(line.len), &written, null);
            }
        } else {
            if (self.posix_file) |fp| {
                _ = fwrite(line.ptr, 1, line.len, fp);
                _ = fflush(fp);
            }
        }
    }
};

/// Formats a Unix epoch timestamp (seconds) as ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`).
pub fn formatUtcTimestamp(buf: []u8, epoch_secs: i64) []const u8 {
    const secs_per_day: i64 = 86_400;
    const days_since_epoch = @divFloor(epoch_secs, secs_per_day);
    const secs_of_day: u64 = @intCast(@mod(epoch_secs, secs_per_day));

    const z = days_since_epoch + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe: u64 = @intCast(z - era * 146_097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y_signed: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const day: u64 = doy - (153 * mp + 2) / 5 + 1;
    const month: u64 = if (mp < 10) mp + 3 else mp - 9;
    const year: u64 = @intCast(y_signed + @as(i64, if (month <= 2) 1 else 0));

    const hour = secs_of_day / 3600;
    const min = (secs_of_day % 3600) / 60;
    const sec = secs_of_day % 60;

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year,
        month,
        day,
        hour,
        min,
        sec,
    }) catch "1970-01-01T00:00:00Z";
}

test "formats UTC ISO-8601 timestamps accurately" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", formatUtcTimestamp(&buf, 0));
    try std.testing.expectEqualStrings("2023-11-14T22:13:20Z", formatUtcTimestamp(&buf, 1_700_000_000));
}
