// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const root = @import("root.zig");

const HANDLE = ?*anyopaque;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const OPEN_EXISTING: u32 = 3;

const win = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
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
    extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: u32,
        lpNumberOfBytesRead: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
} else struct {};

const posix = if (builtin.os.tag != .windows) struct {
    const AF_UNIX: c_int = 1;
    const SOCK_STREAM: c_int = 1;
    const sockaddr_un = extern struct {
        sun_family: u16,
        sun_path: [108]u8,
    };
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn getpid() c_int;
    extern "c" fn getuid() u32;
    extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
    extern "c" fn connect(fd: c_int, addr: *const anyopaque, addrlen: u32) c_int;
    extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
} else struct {};

pub const OP_HANDSHAKE: u32 = 0;
pub const OP_FRAME: u32 = 1;

const FixedWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn writeAll(self: *FixedWriter, bytes: []const u8) error{NoSpaceLeft}!void {
        if (self.pos + bytes.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos .. self.pos + bytes.len], bytes);
        self.pos += bytes.len;
    }

    fn writeByte(self: *FixedWriter, b: u8) error{NoSpaceLeft}!void {
        if (self.pos >= self.buf.len) return error.NoSpaceLeft;
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    fn print(self: *FixedWriter, comptime fmt: []const u8, args: anytype) error{NoSpaceLeft}!void {
        const written = std.fmt.bufPrint(self.buf[self.pos..], fmt, args) catch return error.NoSpaceLeft;
        self.pos += written.len;
    }

    fn slice(self: *const FixedWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

pub fn writeJsonEscaped(w: *FixedWriter, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

pub fn buildActivityJson(
    buf: []u8,
    pid: u32,
    nonce: u64,
    details: []const u8,
    state: ?[]const u8,
    start_ts: ?i64,
    img_cfg: *const config.ImagesConfig,
) ![]const u8 {
    var w = FixedWriter{ .buf = buf };

    try w.writeAll("{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":");
    try w.print("{d}", .{pid});
    try w.writeAll(",\"activity\":{\"details\":");
    try writeJsonEscaped(&w, details);

    if (state) |s| {
        if (s.len > 0) {
            try w.writeAll(",\"state\":");
            try writeJsonEscaped(&w, s);
        }
    }

    if (start_ts) |ts| {
        try w.writeAll(",\"timestamps\":{\"start\":");
        try w.print("{d}", .{ts});
        try w.writeByte('}');
    }

    const large_img = img_cfg.large_image.slice();
    const large_txt = img_cfg.large_image_tooltip.slice();
    const small_img = img_cfg.small_image.slice();
    const small_txt = img_cfg.small_image_tooltip.slice();

    if (large_img.len > 0 or small_img.len > 0) {
        try w.writeAll(",\"assets\":{");
        var first = true;
        if (large_img.len > 0) {
            try w.writeAll("\"large_image\":");
            try writeJsonEscaped(&w, large_img);
            first = false;
            if (large_txt.len > 0) {
                try w.writeAll(",\"large_text\":");
                try writeJsonEscaped(&w, large_txt);
            }
        }
        if (small_img.len > 0) {
            if (!first) try w.writeByte(',');
            try w.writeAll("\"small_image\":");
            try writeJsonEscaped(&w, small_img);
            if (small_txt.len > 0) {
                try w.writeAll(",\"small_text\":");
                try writeJsonEscaped(&w, small_txt);
            }
        }
        try w.writeByte('}');
    }

    try w.writeAll("}},\"nonce\":\"eu5-");
    try w.print("{d}", .{nonce});
    try w.writeAll("\"}");

    return w.slice();
}

pub const DiscordIpc = struct {
    connected: bool = false,
    nonce: u64 = 1,
    win_handle: if (builtin.os.tag == .windows) HANDLE else void = if (builtin.os.tag == .windows) INVALID_HANDLE_VALUE else {},
    unix_fd: if (builtin.os.tag != .windows) c_int else void = if (builtin.os.tag != .windows) -1 else {},

    pub fn connect(self: *DiscordIpc, app_id: []const u8) bool {
        self.close();

        var idx: u32 = 0;
        while (idx < 10) : (idx += 1) {
            if (self.openPipe(idx)) {
                var hs_buf: [256]u8 = undefined;
                const hs = std.fmt.bufPrint(&hs_buf, "{{\"v\":1,\"client_id\":\"{s}\"}}", .{app_id}) catch {
                    self.close();
                    return false;
                };
                if (self.sendFrame(OP_HANDSHAKE, hs) and self.discardReply()) {
                    self.connected = true;
                    return true;
                }
                self.close();
            }
        }
        return false;
    }

    pub fn setActivity(
        self: *DiscordIpc,
        details: []const u8,
        state: ?[]const u8,
        start_ts: ?i64,
        img_cfg: *const config.ImagesConfig,
    ) bool {
        if (!self.connected) return false;
        self.nonce += 1;

        var json_buf: [2048]u8 = undefined;
        const pid: u32 = if (builtin.os.tag == .windows)
            win.GetCurrentProcessId()
        else
            @intCast(posix.getpid());

        const payload = buildActivityJson(
            &json_buf,
            pid,
            self.nonce,
            details,
            state,
            start_ts,
            img_cfg,
        ) catch return false;

        if (!self.sendFrame(OP_FRAME, payload) or !self.discardReply()) {
            self.close();
            return false;
        }
        return true;
    }

    pub fn clearActivity(self: *DiscordIpc) void {
        if (!self.connected) return;
        self.nonce += 1;
        const pid: u32 = if (builtin.os.tag == .windows)
            win.GetCurrentProcessId()
        else
            @intCast(posix.getpid());

        var json_buf: [256]u8 = undefined;
        const payload = std.fmt.bufPrint(
            &json_buf,
            "{{\"cmd\":\"SET_ACTIVITY\",\"args\":{{\"pid\":{d},\"activity\":null}},\"nonce\":\"eu5-{d}\"}}",
            .{ pid, self.nonce },
        ) catch return;
        _ = self.sendFrame(OP_FRAME, payload);
        _ = self.discardReply();
    }

    pub fn close(self: *DiscordIpc) void {
        if (builtin.os.tag == .windows) {
            if (self.win_handle != INVALID_HANDLE_VALUE) {
                _ = win.CloseHandle(self.win_handle);
                self.win_handle = INVALID_HANDLE_VALUE;
            }
        } else {
            if (self.unix_fd >= 0) {
                _ = posix.close(self.unix_fd);
                self.unix_fd = -1;
            }
        }
        self.connected = false;
    }

    fn openPipe(self: *DiscordIpc, idx: u32) bool {
        if (builtin.os.tag == .windows) {
            var path_buf: [64]u8 = undefined;
            const path = root.bufPrintZ(&path_buf, "\\\\.\\pipe\\discord-ipc-{d}", .{idx}) catch return false;
            const h = win.CreateFileA(
                path.ptr,
                GENERIC_READ | GENERIC_WRITE,
                0,
                null,
                OPEN_EXISTING,
                0,
                null,
            );
            if (h == INVALID_HANDLE_VALUE) return false;
            self.win_handle = h;
            return true;
        } else {
            var run_user_buf: [64]u8 = undefined;
            const run_user = root.bufPrintZ(&run_user_buf, "/run/user/{d}", .{posix.getuid()}) catch null;
            const dirs = [_]?[*:0]const u8{
                posix.getenv("XDG_RUNTIME_DIR"),
                if (run_user) |ru| ru.ptr else null,
                posix.getenv("TMPDIR"),
                posix.getenv("TMP"),
                posix.getenv("TEMP"),
                "/tmp",
            };
            // Supports native Discord, Flatpak (Discord, Canary, PTB, Vesktop, ArmCord, Equibop, Legcord), and Snap across all Linux distros & DEs.
            const suffixes = [_][]const u8{
                "",
                "/app/com.discordapp.Discord",
                "/app/com.discordapp.DiscordCanary",
                "/app/com.discordapp.DiscordPTB",
                "/app/dev.vencord.Vesktop",
                "/app/xyz.armcord.ArmCord",
                "/app/io.github.equicord.equibop",
                "/app/app.legcord.Legcord",
                "/snap.discord",
                "/snap.discord-canary",
                "/snap.discord-ptb",
            };
            for (dirs) |maybe_dir| {
                const dir_ptr = maybe_dir orelse continue;
                const dir = std.mem.trimEnd(u8, std.mem.span(dir_ptr), "/");
                if (dir.len == 0) continue;
                for (suffixes) |suf| {
                    const fd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0);
                    if (fd < 0) continue;

                    var addr = std.mem.zeroes(posix.sockaddr_un);
                    addr.sun_family = @intCast(posix.AF_UNIX);
                    _ = root.bufPrintZ(addr.sun_path[0..107], "{s}{s}/discord-ipc-{d}", .{ dir, suf, idx }) catch {
                        _ = posix.close(fd);
                        continue;
                    };
                    if (posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr_un)) == 0) {
                        self.unix_fd = fd;
                        return true;
                    }
                    _ = posix.close(fd);
                }
            }
            return false;
        }
    }

    fn sendFrame(self: *DiscordIpc, opcode: u32, body: []const u8) bool {
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], opcode, .little);
        std.mem.writeInt(u32, header[4..8], @intCast(body.len), .little);
        return self.writeAll(&header) and self.writeAll(body);
    }

    fn discardReply(self: *DiscordIpc) bool {
        var header: [8]u8 = undefined;
        if (!self.readExact(&header)) return false;
        const len = std.mem.readInt(u32, header[4..8], .little);
        if (len > 65536) return false;
        var sink: [512]u8 = undefined;
        var rem: usize = len;
        while (rem > 0) {
            const chunk = @min(rem, sink.len);
            if (!self.readExact(sink[0..chunk])) return false;
            rem -= chunk;
        }
        return true;
    }

    fn writeAll(self: *DiscordIpc, data: []const u8) bool {
        var off: usize = 0;
        while (off < data.len) {
            if (builtin.os.tag == .windows) {
                var written: u32 = 0;
                if (win.WriteFile(self.win_handle, data.ptr + off, @intCast(data.len - off), &written, null) == 0 or written == 0) {
                    return false;
                }
                off += written;
            } else {
                const n = posix.write(self.unix_fd, data.ptr + off, data.len - off);
                if (n <= 0) return false;
                off += @intCast(n);
            }
        }
        return true;
    }

    fn readExact(self: *DiscordIpc, out: []u8) bool {
        var off: usize = 0;
        while (off < out.len) {
            if (builtin.os.tag == .windows) {
                var got: u32 = 0;
                if (win.ReadFile(self.win_handle, out.ptr + off, @intCast(out.len - off), &got, null) == 0 or got == 0) {
                    return false;
                }
                off += got;
            } else {
                const n = posix.read(self.unix_fd, out.ptr + off, out.len - off);
                if (n <= 0) return false;
                off += @intCast(n);
            }
        }
        return true;
    }
};

test "builds valid escaped EU5 Discord SET_ACTIVITY JSON payload" {
    const cfg = config.Config{};
    var buf: [1024]u8 = undefined;
    const json = try buildActivityJson(
        &buf,
        4242,
        7,
        "Playing as \"France\" (1454)",
        "Age of Renaissance · Singleplayer · v1.4.7",
        1_700_000_000,
        &cfg.images,
    );
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cmd\":\"SET_ACTIVITY\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"France\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"start\":1700000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, root.DEFAULT_LARGE_IMAGE_URL) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nonce\":\"eu5-7\"") != null);
}
