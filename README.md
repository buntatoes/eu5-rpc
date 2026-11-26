<div align="center">
  <img src="assets/icon.png" alt="EU5 RPC" width="120" />

  # EU5 Rich Presence for Discord

  Show your **Europa Universalis V** country, current year, historical Age, campaign mode (Singleplayer / Multiplayer / Observer), game version, and live wars/disasters on your Discord profile automatically. Free, open-source, zero-dependency Ruby tool for **Windows (`.exe` installer)** and **Linux**, licensed under **GPL-3.0**.

  [![Latest Release](https://img.shields.io/github/v/release/buntatoes/eu5-rpc?label=release)](https://github.com/buntatoes/eu5-rpc/releases/latest)
  [![CI](https://img.shields.io/github/actions/workflow/status/buntatoes/eu5-rpc/ci.yml?branch=main&label=CI)](https://github.com/buntatoes/eu5-rpc/actions/workflows/ci.yml)
  [![Ruby](https://img.shields.io/badge/language-Ruby%203.2%2B-CC342D?logo=ruby&logoColor=white)](#installation--setup)
  [![Platform](https://img.shields.io/badge/platform-Windows%20(.exe)%20%7C%20Linux-blue)](#installation--setup)
  [![License: GPL v3](https://img.shields.io/github/license/buntatoes/eu5-rpc)](LICENSE)

</div>

## Features

- **100% Pure Ruby Core (Zero External Gems)**: Runs on standard Ruby (`3.2+` / `3.4+`) using only the Ruby standard library (`json`, `socket`, `fiddle`, `win32/registry`, `zlib`).
- **Accurate Live EU5 Telemetry**:
  - Reads `logs/debug.log` transitions (`SplashScreen`, `LoadingScreen`, `MainMenu`, `Game`, `Empty`) and game version (`1.4.x`).
  - Reads `logs/multiplayer.log` for Singleplayer, Multiplayer, Multiplayer Host, and Observer state.
  - Reads `logs/game.log` for live `NEW YEAR` updates, wars, civil wars, explorations, and disasters.
  - Reads `continue_game.json` and the latest `.eu5` save header (`save games/*.eu5`) for your exact played country name, tag, and date — works with any vanilla, formable, or modded nation.
  - Displays EU5's six historical Ages beginning in `1337` (`Age of Traditions`, `Age of Renaissance`, `Age of Discovery`, `Age of Reformation`, `Age of Absolutism`, `Age of Revolutions`).
- **Ironman & Achievement Safe**: Strictly read-only — never reads game memory, modifies save files, installs mods, or intercepts network traffic.
- **Zero Console Popups**: Uses native Win32 `CreateToolhelp32Snapshot` via Ruby `Fiddle` on Windows (and `/proc` on Linux) to detect `eu5.exe`.
- **Windows `.exe` Installer + Desktop Shortcut**: `EU5-RPC-Setup-v0.2-win64.exe` installs `eu5-rpc.exe` to `%LOCALAPPDATA%\EU5-RPC`, creates Desktop & Start Menu shortcuts that launch Europa Universalis V (Steam AppID `3450310`) with Discord Rich Presence, and registers Windows Add/Remove Programs uninstall support.
- **Linux Package**: `eu5-rpc-linux-x86_64.tar.gz` includes an XDG desktop entry and `install.sh` installer for `~/.local`.

## Installation & Setup

Requires [Ruby 3.2+](https://www.ruby-lang.org/) (tested on Ruby 3.4) and the Discord desktop app running. **No Discord Developer Portal setup or manual App ID is required** — EU5 RPC automatically links into your currently logged-in Discord desktop session over local IPC using Discord's official public `Europa Universalis V` catalog ID (`1435327845051400292`).

### Windows (`.exe` Installer)

1. Download `EU5-RPC-Setup-v0.2-win64.exe` from the [Releases](../../releases) page (or build from source with `ruby scripts/package.rb --exe`).
2. Run `EU5-RPC-Setup-v0.2-win64.exe` to install to `%LOCALAPPDATA%\EU5-RPC` and create the **"EU5 RPC"** Desktop shortcut.
3. Double-click **"EU5 RPC"** on your Desktop to launch Europa Universalis V with Discord Rich Presence automatically.

### Linux (`.tar.gz` / XDG Desktop Installer)

```bash
tar -xzf eu5-rpc-linux-x86_64.tar.gz
cd eu5-rpc-linux-x86_64
./install.sh
eu5-rpc
```

## CLI Flags

| Flag | Description |
|------|-------------|
| `--no-launch` | Skip launching Europa Universalis V via Steam on startup. |
| `--launch-with-command -- <command>` | Launch a custom command (for Steam `%command%` launch options). |
| `--generate-config` | Write a fresh `config.toml` with default settings and exit. |
| `-v`, `--version` | Print version (`v0.2.0`) and exit. |
| `-h`, `--help` | Show CLI usage help. |

## Building & Testing from Source

```bash
git clone https://github.com/buntatoes/eu5-rpc.git
cd eu5-rpc

# Run unit tests
ruby -Ilib:test test/test_eu5_rpc.rb

# Build dist/EU5-RPC-Setup-v0.2-win64.exe and dist/eu5-rpc-linux-x86_64.tar.gz
ruby scripts/package.rb
```

## License & Disclaimer

Licensed under the **GNU General Public License v3.0 ([GPL-3.0](LICENSE))** by **Buntato**.

Not affiliated with, endorsed by, or connected to Paradox Interactive AB. **Europa Universalis V** and all related names and trademarks are the property of **Paradox Interactive AB**.
