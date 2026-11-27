<div align="center">
  <img src="assets/icon.png" alt="EU5 RPC" width="120" />

  # EU5 Rich Presence for Discord

  Show your **Europa Universalis V** country, current year, historical Age, campaign mode (Singleplayer / Multiplayer / Observer), game version, and live wars/disasters on your Discord profile automatically — including mid-game nation swaps, formables, and custom nations. Free, open-source, **100% pure Zig** native tool for **Windows (`.exe` installer)** and **Linux (Native & Proton)**, licensed under **GPL-3.0**.

  <p>
    <a href="https://github.com/buntatoes/eu5-rpc/releases/latest"><img src="https://img.shields.io/badge/release-v4.0.0-blue" alt="Latest Release" /></a>
    <a href="https://github.com/buntatoes/eu5-rpc/actions/workflows/ci.yml"><img src="https://github.com/buntatoes/eu5-rpc/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI" /></a>
    <a href="#building--packaging-from-source"><img src="assets/badge-zig.svg" alt="Language: Zig 0.17" /></a>
    <a href="#installation--setup"><img src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20Proton-blue" alt="Platform: Windows | Linux | Proton" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License: GPL-3.0" /></a>
  </p>

</div>

## Preview

<div align="center">
  <img src="assets/demo.gif" alt="EU5 Discord Rich Presence cycling live across Kingdom of Hungary, Crown of Castile, Kingdom of Sweden at war, and Kingdom of England in the Hundred Years' War" width="416" />
</div>

## Features

- **100% Pure Zig (Zero Runtime Dependencies)**: Every component — the EU5 telemetry daemon, Discord IPC client, TOML config manager, Windows GUI setup installer, Linux desktop integrator, and `.tar.gz` packager — is written strictly in Zig. End users need no external runtime installed.
- **User-, Distro-, DE-, & Windows-Agnostic**:
  - **Linux**: Works across distros and desktop environments (KDE Plasma, GNOME, XFCE, Wayland/X11) with native, Debian, Flatpak, Snap, and custom Steam/Proton/Wine setups — detecting `eu5` / `eu5.exe` natively or under Proton, Wine, Steam Linux Runtime, Gamescope, GameMode, MangoHud, and `umu-run`, and connecting to native, Flatpak, or Snap Discord clients (including Canary, PTB, Vesktop, ArmCord, Equibop, and Legcord).
  - **Windows**: Full UTF-16 Unicode support across Windows 10/11 locales, non-ASCII usernames, OneDrive-redirected `Documents`, multi-drive Steam libraries, and shared-read access to live EU5 logs/saves with zero console popups.
- **Full Live EU5 Telemetry**:
  - Passive live **Steam Rich Presence** across all **11 official EU5 languages** (English, French, German, Spanish, Brazilian Portuguese, Polish, Russian, Turkish, Japanese, Korean, and Simplified Chinese) scoped to Steam AppID `3450310`.
  - Live log tailing (`logs/debug.log`, `logs/multiplayer.log`, `logs/game.log`), `continue_game.json` & `.eu5` save header inspection, dynamic `CountryLookup` from EU5 localization files, and all six historical Ages starting in `1337` (`Age of Traditions`, `Age of Renaissance`, `Age of Discovery`, `Age of Reformation`, `Age of Absolutism`, `Age of Revolutions`).
  - Customizable `config.toml` templates (`{country}`, `{tag}`, `{year}`, `{date}`, `{age}`), poll/update intervals, and image assets (`--generate-config`).
- **100% VAC-Safe, Ironman & Achievement Safe**: Strictly external and read-only — never calls `OpenProcess` or `ReadProcessMemory`, never injects DLLs or hooks game code, never reads `/proc/<pid>/mem` or calls `ptrace`, never modifies save files or checksums, and never calls `SteamAPI_Init`.
- **Zero-Setup Discord Linking**: Automatically links with your running Discord desktop client over local IPC using Discord's official public `Europa Universalis V` catalog ID (`1435327845051400292`).

## Installation & Setup

Requires Steam, Europa Universalis V, and a running Discord desktop client. **No Discord Developer Portal setup or manual App ID is required.**

### Windows (`.exe` Installer)

1. Download `EU5-RPC-Setup-v4.0.0-win64.exe` from the [Releases](../../releases/latest) page.
2. Run the installer to install to `%LOCALAPPDATA%\EU5-RPC` (automatically cleans up legacy Ruby files while keeping your `config.toml`) and create the **"EU5 RPC"** Desktop and Start Menu shortcuts.
3. Double-click **"EU5 RPC"** on your Desktop to launch Europa Universalis V with Discord Rich Presence automatically.

> [!NOTE]
> Windows may show a **"Windows protected your PC"** warning. This happens because the app is not signed, not because it is harmful. Click **More info**, then **Run anyway**. If you'd rather verify the code yourself, [build from source](#building--packaging-from-source).

### Linux (`.tar.gz` Native Binary)

```bash
tar -xzf eu5-rpc-linux-x86_64.tar.gz
cd eu5-rpc-linux-x86_64
./eu5-rpc --install
eu5-rpc
```

## CLI Flags

| Flag | Description |
|------|-------------|
| `--no-launch` | Skip launching Europa Universalis V via Steam on startup. |
| `--keep-open` | Keep running after Europa Universalis V closes. |
| `--once` | Probe current EU5 telemetry once, print status, and exit. |
| `--launch-with-command -- <command>` | Launch a custom command (for Steam `%command%` launch options). |
| `--generate-config` | Write a fresh `config.toml` with default settings and exit. |
| `--install` | Install binary, icon, and XDG desktop entry to `~/.local` (Linux). |
| `--uninstall` | Remove installed binary and XDG desktop entry (Linux). |
| `-v`, `--version` | Print version (`v4.0.0`) and exit. |
| `-h`, `--help` | Show CLI usage help. |

## Building & Packaging from Source

Requires only [Zig 0.17.1](https://ziglang.org/download/).

```bash
git clone https://github.com/buntatoes/eu5-rpc.git
cd eu5-rpc

# Run unit tests
zig build test

# Build optimized native executable
zig build -Doptimize=ReleaseSafe

# Build both dist/EU5-RPC-Setup-v4.0.0-win64.exe and dist/eu5-rpc-linux-x86_64.tar.gz
zig build package
```

## Reporting Bugs & Security Issues

- **Bugs & Feature Requests**: Open an issue using the [Issue Templates](../../issues/new/choose).
- **Security Vulnerabilities**: Report privately via [GitHub Security Advisories](https://github.com/buntatoes/eu5-rpc/security/advisories/new) (see [SECURITY.md](SECURITY.md)).

## License & Disclaimer

Licensed under the **GNU General Public License v3.0 ([GPL-3.0](LICENSE))** (`SPDX-License-Identifier: GPL-3.0-only`) by **Buntato**.

Not affiliated with, endorsed by, or connected to Paradox Interactive AB. **Europa Universalis V** and all related names and trademarks are the property of **Paradox Interactive AB**.
