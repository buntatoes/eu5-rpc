// SPDX-License-Identifier: GPL-3.0-only
// 100% Pure Zig release packager for EU5 RPC:
// Writes a POSIX USTAR .tar.gz archive (preserving 0755 executable permissions on the Linux ELF binary)
// using Zig's built-in std.compress.flate gzip compressor.
const std = @import("std");

const FILE = anyopaque;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *FILE) c_long;
extern "c" fn fclose(stream: *FILE) c_int;
extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;

const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;

fn readFileAlloc(allocator: std.mem.Allocator, path_z: [*:0]const u8) ![]u8 {
    const fp = fopen(path_z, "rb") orelse return error.FileNotFound;
    defer _ = fclose(fp);

    _ = fseek(fp, 0, SEEK_END);
    const sz_long = ftell(fp);
    if (sz_long < 0) return error.IoError;
    _ = fseek(fp, 0, SEEK_SET);

    const sz: usize = @intCast(sz_long);
    const buf = try allocator.alloc(u8, sz);
    if (sz > 0) {
        const got = fread(buf.ptr, 1, sz, fp);
        if (got != sz) return error.IoError;
    }
    return buf;
}

fn writeFileAll(path_z: [*:0]const u8, data: []const u8) !void {
    const fp = fopen(path_z, "wb") orelse return error.OpenFailed;
    defer _ = fclose(fp);
    if (data.len > 0) {
        if (fwrite(data.ptr, 1, data.len, fp) != data.len) return error.WriteFailed;
    }
}

fn writeOctal(dst: []u8, value: usize) void {
    @memset(dst, '0');
    dst[dst.len - 1] = 0;
    var v = value;
    var i: usize = dst.len - 1;
    while (i > 0) {
        i -= 1;
        dst[i] = @intCast('0' + (v & 7));
        v >>= 3;
    }
}

fn appendTarEntry(
    tar_buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    entry_name: []const u8,
    mode: usize,
    data: []const u8,
) !void {
    var hdr: [512]u8 = std.mem.zeroes([512]u8);

    const name_len = @min(entry_name.len, 100);
    @memcpy(hdr[0..name_len], entry_name[0..name_len]);
    writeOctal(hdr[100..108], mode);
    writeOctal(hdr[108..116], 0);
    writeOctal(hdr[116..124], 0);
    writeOctal(hdr[124..136], data.len);
    writeOctal(hdr[136..148], 1700000000);
    @memset(hdr[148..156], ' ');
    hdr[156] = '0';
    @memcpy(hdr[257..263], "ustar\x00");
    @memcpy(hdr[263..265], "00");

    var sum: usize = 0;
    for (hdr) |b| sum += b;
    writeOctal(hdr[148..155], sum);
    hdr[155] = ' ';

    try tar_buf.appendSlice(allocator, &hdr);
    try tar_buf.appendSlice(allocator, data);

    const rem = data.len % 512;
    if (rem != 0) {
        var pad: [512]u8 = std.mem.zeroes([512]u8);
        try tar_buf.appendSlice(allocator, pad[0 .. 512 - rem]);
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 7) {
        _ = printf("Usage: packager <out.tar.gz> <linux_elf> <license> <readme> <icon_png> <icon_ico>\n");
        return error.InvalidArguments;
    }

    const out_path = args[1];
    const elf_path = args[2];
    const lic_path = args[3];
    const rdm_path = args[4];
    const png_path = args[5];
    const ico_path = args[6];

    const elf_data = try readFileAlloc(arena, elf_path.ptr);
    const lic_data = try readFileAlloc(arena, lic_path.ptr);
    const rdm_data = try readFileAlloc(arena, rdm_path.ptr);
    const png_data = try readFileAlloc(arena, png_path.ptr);
    const ico_data = try readFileAlloc(arena, ico_path.ptr);

    var tar_buf = std.ArrayList(u8).empty;
    try appendTarEntry(&tar_buf, arena, "eu5-rpc-linux-x86_64/eu5-rpc", 0o755, elf_data);
    try appendTarEntry(&tar_buf, arena, "eu5-rpc-linux-x86_64/LICENSE", 0o644, lic_data);
    try appendTarEntry(&tar_buf, arena, "eu5-rpc-linux-x86_64/README.md", 0o644, rdm_data);
    try appendTarEntry(&tar_buf, arena, "eu5-rpc-linux-x86_64/assets/icon.png", 0o644, png_data);
    try appendTarEntry(&tar_buf, arena, "eu5-rpc-linux-x86_64/assets/icon.ico", 0o644, ico_data);

    // End-of-archive marker (two 512-byte zero blocks)
    var zeros: [1024]u8 = std.mem.zeroes([1024]u8);
    try tar_buf.appendSlice(arena, &zeros);

    const out_buf = try arena.alloc(u8, tar_buf.items.len + 131072);
    var out_writer = std.Io.Writer.fixed(out_buf);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);

    var comp = try std.compress.flate.Compress.init(&out_writer, window, .gzip, .default);
    try comp.writer.writeAll(tar_buf.items);
    try comp.finish();

    const gz_bytes = out_writer.buffered();
    try writeFileAll(out_path.ptr, gz_bytes);
    _ = printf("[package] Built Linux archive: %s (%zu bytes)\n", out_path.ptr, gz_bytes.len);
}
