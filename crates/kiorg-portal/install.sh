#!/usr/bin/env bash
# Install xdg-desktop-portal-kiorg.
# Run as root (for system install) or without for user install.
set -euo pipefail

BINARY="xdg-desktop-portal-kiorg"
PORTAL_FILE="kiorg.portal"
DBUS_SERVICE="org.freedesktop.impl.portal.desktop.kiorg.service"
SYSTEMD_SERVICE="xdg-desktop-portal-kiorg.service"

if [[ $EUID -eq 0 ]]; then
    BIN_DIR="/usr/lib"
    PORTAL_DIR="/usr/share/xdg-desktop-portal/portals"
    DBUS_DIR="/usr/share/dbus-1/services"
    SYSTEMD_DIR="/usr/lib/systemd/user"
else
    BIN_DIR="$HOME/.local/bin"
    PORTAL_DIR="$HOME/.local/share/xdg-desktop-portal/portals"
    DBUS_DIR="$HOME/.local/share/dbus-1/services"
    SYSTEMD_DIR="$HOME/.config/systemd/user"
fi

mkdir -p "$BIN_DIR" "$PORTAL_DIR" "$DBUS_DIR" "$SYSTEMD_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILT_BINARY="$REPO_ROOT/target/release/$BINARY"
if [[ ! -f "$BUILT_BINARY" ]]; then
    echo "Binary not found. Building..."
    cargo build --release -p kiorg-portal
fi

install -m755 "$BUILT_BINARY" "$BIN_DIR/$BINARY"
install -m644 "$SCRIPT_DIR/data/$PORTAL_FILE"   "$PORTAL_DIR/$PORTAL_FILE"
install -m644 "$SCRIPT_DIR/data/$DBUS_SERVICE"  "$DBUS_DIR/$DBUS_SERVICE"
install -m644 "$SCRIPT_DIR/data/$SYSTEMD_SERVICE" "$SYSTEMD_DIR/$SYSTEMD_SERVICE"

if [[ $EUID -ne 0 ]]; then
    systemctl --user daemon-reload
    systemctl --user enable --now xdg-desktop-portal-kiorg.service || true
fi

echo "Installed xdg-desktop-portal-kiorg."
echo ""
echo "To make applications use kiorg as the file picker:"
echo "  - Set XDG_CURRENT_DESKTOP=kiorg  (or add 'kiorg' to the UseIn list in kiorg.portal)"
echo "  - For GTK apps: GTK_USE_PORTAL=1"
echo "  - For Firefox:  set widget.use-xdg-desktop-portal.file-picker=1 in about:config"
echo "  - For Qt apps:  QT_QPA_PLATFORMTHEME=xdgdesktopportal"
