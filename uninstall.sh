#!/usr/bin/env bash
# ==============================================================================
# ExifCleaner AutoSend - Uninstaller
# ==============================================================================
set -euo pipefail

BOLD='\033[1m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BOLD}${BLUE}=== ExifCleaner AutoSend Uninstaller ===${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}Root privileges required. Elevating via sudo...${NC}"
    exec sudo bash "$0" "$@"
fi

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un 1000 2>/dev/null || echo "root")}"
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
USER_UID="$(id -u "$TARGET_USER")"

echo -e "Stopping user services..."
USER_RUNTIME="/run/user/${USER_UID}"
if [[ -d "$USER_RUNTIME" && "$TARGET_USER" != "root" ]]; then
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$USER_RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=${USER_RUNTIME}/bus" systemctl --user stop safesend-watcher.service safesend-clipboard.service 2>/dev/null || true
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$USER_RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=${USER_RUNTIME}/bus" systemctl --user disable safesend-watcher.service safesend-clipboard.service 2>/dev/null || true
fi

echo -e "Removing user files & configurations..."
if [[ -n "$USER_HOME" && -d "$USER_HOME" ]]; then
    rm -f "$USER_HOME/.config/systemd/user/safesend-watcher.service"
    rm -f "$USER_HOME/.config/systemd/user/safesend-clipboard.service"
    rm -rf "$USER_HOME/.config/systemd/user/xdg-desktop-portal-gtk.service.d"
    rm -f "$USER_HOME/.local/share/nemo/actions/safesend.nemo_action"
    rm -f "$USER_HOME/.local/share/nautilus/scripts/Safe Send (Strip Metadata & Copy)"
    rm -f "$USER_HOME/.local/share/kio/servicemenus/safesend.desktop"
fi

if [[ -d "$USER_RUNTIME" && "$TARGET_USER" != "root" ]]; then
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$USER_RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=${USER_RUNTIME}/bus" systemctl --user daemon-reload 2>/dev/null || true
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$USER_RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=${USER_RUNTIME}/bus" systemctl --user restart xdg-desktop-portal-gtk.service 2>/dev/null || true
fi

echo -e "Removing system binaries and libraries..."
rm -f /usr/local/lib/libcleanupload.so
rm -f /usr/local/bin/clean-for-send
rm -f /usr/local/bin/clean-auto-purge
rm -f /usr/local/bin/clean-clipboard-send
rm -f /usr/local/bin/safesend
rm -f /usr/local/bin/safesend-watcher
rm -f /usr/local/bin/safesend-clipboard
rm -f /usr/share/applications/SafeSend.desktop

# Remove wrappers if they point to libcleanupload
for bin in google-chrome-stable google-chrome discord telegram-desktop; do
    if [[ -f "/usr/local/bin/$bin" ]] && grep -q "libcleanupload" "/usr/local/bin/$bin"; then
        rm -f "/usr/local/bin/$bin"
    fi
done

rm -f /etc/environment.d/50-cleanupload.conf
rm -f /etc/profile.d/cleanupload.sh
rm -rf /dev/shm/.clean_send
ldconfig 2>/dev/null || true

echo -e "\n${BOLD}${GREEN}ExifCleaner AutoSend has been completely removed.${NC}\n"
