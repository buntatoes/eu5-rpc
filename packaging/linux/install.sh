#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
APP_DIR="$PREFIX/share/eu5-rpc"
BIN_DIR="$PREFIX/bin"
DESKTOP_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor/256x256/apps"

mkdir -p "$APP_DIR/bin" "$APP_DIR/lib" "$APP_DIR/assets" "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR"

cp -r "$SCRIPT_DIR/bin/"* "$APP_DIR/bin/"
cp -r "$SCRIPT_DIR/lib/"* "$APP_DIR/lib/"
cp -r "$SCRIPT_DIR/assets/"* "$APP_DIR/assets/"
cp "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/README.md" "$APP_DIR/"
chmod +x "$APP_DIR/bin/eu5-rpc"

if [ -f "$SCRIPT_DIR/eu5-rpc" ]; then
    cp "$SCRIPT_DIR/eu5-rpc" "$APP_DIR/eu5-rpc"
    chmod +x "$APP_DIR/eu5-rpc"
    ln -sf "$APP_DIR/eu5-rpc" "$BIN_DIR/eu5-rpc"
else
    ln -sf "$APP_DIR/bin/eu5-rpc" "$BIN_DIR/eu5-rpc"
fi

cp "$SCRIPT_DIR/assets/icon.png" "$ICON_DIR/eu5-rpc.png"

sed "s|^Exec=.*|Exec=$BIN_DIR/eu5-rpc|" \
    "$SCRIPT_DIR/packaging/linux/eu5-rpc.desktop" > "$DESKTOP_DIR/eu5-rpc.desktop"

echo "Installed EU5 RPC to $APP_DIR"
echo "Run with: $BIN_DIR/eu5-rpc"
