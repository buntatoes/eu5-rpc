// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");

fn addCoreExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = (optimize != .debug),
    });

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = (optimize != .debug),
        .imports = &.{
            .{ .name = "eu5_rpc", .module = mod },
        },
    });
    main_mod.addAnonymousImport("icon_png", .{
        .root_source_file = b.path("assets/icon.png"),
    });

    const exe = b.addExecutable(.{
        .name = "eu5-rpc",
        .root_module = main_mod,
    });

    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("kernel32", .{});
        mod.linkSystemLibrary("advapi32", .{});
        mod.linkSystemLibrary("shell32", .{});
        mod.linkSystemLibrary("user32", .{});
        exe.root_module.linkSystemLibrary("kernel32", .{});
        exe.root_module.linkSystemLibrary("advapi32", .{});
        exe.root_module.linkSystemLibrary("shell32", .{});
        exe.root_module.linkSystemLibrary("user32", .{});
        if (optimize != .debug) {
            exe.subsystem = .windows;
        }
    }

    return exe;
}

fn attachWindowsIcon(b: *std.Build, mod: *std.Build.Module) void {
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path("assets/icon.ico"), "icon.ico");
    const rc = wf.add("icon.rc", "1 ICON \"icon.ico\"\n");
    mod.addWin32ResourceFile(.{ .file = rc });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Default native target
    const exe = addCoreExecutable(b, target, optimize);
    if (target.result.os.tag == .windows) {
        attachWindowsIcon(b, exe.root_module);
    }
    b.installArtifact(exe);

    // Unit tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .windows) {
        test_mod.linkSystemLibrary("kernel32", .{});
        test_mod.linkSystemLibrary("advapi32", .{});
        test_mod.linkSystemLibrary("shell32", .{});
        test_mod.linkSystemLibrary("user32", .{});
    }
    const mod_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run EU5 RPC unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // 100% Pure Zig release packaging step (`zig build package`):
    // Builds BOTH Windows GUI setup installer and Linux x86_64 .tar.gz into dist/
    const package_step = b.step("package", "Build Windows .exe setup installer and Linux .tar.gz into dist/");

    // 1. Windows x86_64 ReleaseSafe eu5-rpc.exe + GUI Setup Installer
    const win_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const win_exe = addCoreExecutable(b, win_target, .safe);
    attachWindowsIcon(b, win_exe.root_module);

    const installer_mod = b.createModule(.{
        .root_source_file = b.path("src/installer_win.zig"),
        .target = win_target,
        .optimize = .safe,
        .link_libc = true,
        .strip = true,
    });
    installer_mod.addAnonymousImport("payload_exe", .{ .root_source_file = win_exe.getEmittedBin() });
    installer_mod.addAnonymousImport("icon_ico", .{ .root_source_file = b.path("assets/icon.ico") });
    installer_mod.addAnonymousImport("icon_png", .{ .root_source_file = b.path("assets/icon.png") });
    installer_mod.addAnonymousImport("license_txt", .{ .root_source_file = b.path("LICENSE") });
    installer_mod.addAnonymousImport("readme_md", .{ .root_source_file = b.path("README.md") });
    installer_mod.linkSystemLibrary("kernel32", .{});
    installer_mod.linkSystemLibrary("user32", .{});
    installer_mod.linkSystemLibrary("shell32", .{});
    installer_mod.linkSystemLibrary("ole32", .{});
    installer_mod.linkSystemLibrary("advapi32", .{});
    attachWindowsIcon(b, installer_mod);

    const setup_exe = b.addExecutable(.{
        .name = "EU5-RPC-Setup-v4.0.0-win64",
        .root_module = installer_mod,
    });
    setup_exe.subsystem = .windows;

    const install_setup = b.addInstallFileWithDir(
        setup_exe.getEmittedBin(),
        .{ .custom = "../dist" },
        "EU5-RPC-Setup-v4.0.0-win64.exe",
    );
    package_step.dependOn(&install_setup.step);

    // 2. Linux x86_64 ReleaseSafe eu5-rpc + pure Zig .tar.gz archive
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
        .glibc_version = .{ .major = 2, .minor = 31, .patch = 0 },
    });
    const linux_exe = addCoreExecutable(b, linux_target, .safe);

    const packager_exe = b.addExecutable(.{
        .name = "packager",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/packager.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .link_libc = true,
        }),
    });

    const run_packager = b.addRunArtifact(packager_exe);
    const out_tar_gz = run_packager.addOutputFileArg("eu5-rpc-linux-x86_64.tar.gz");
    run_packager.addFileArg(linux_exe.getEmittedBin());
    run_packager.addFileArg(b.path("LICENSE"));
    run_packager.addFileArg(b.path("README.md"));
    run_packager.addFileArg(b.path("assets/icon.png"));
    run_packager.addFileArg(b.path("assets/icon.ico"));

    const install_tar_gz = b.addInstallFileWithDir(
        out_tar_gz,
        .{ .custom = "../dist" },
        "eu5-rpc-linux-x86_64.tar.gz",
    );
    package_step.dependOn(&install_tar_gz.step);
}
