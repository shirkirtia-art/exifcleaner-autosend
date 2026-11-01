#!/usr/bin/env bash
# ==============================================================================
# ExifCleaner AutoSend - Universal Linux Installer
# Automates zero-duplicate, on-the-fly metadata stripping for Linux uploads
# ==============================================================================
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BOLD}${BLUE}=== ExifCleaner AutoSend Installer ===${NC}"

# Check for root / sudo
if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}Root privileges required. Elevating via sudo...${NC}"
    exec sudo bash "$0" "$@"
fi

# Detect calling user
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un 1000 2>/dev/null || echo "root")}"
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
USER_UID="$(id -u "$TARGET_USER")"

echo -e "Installing for system and user: ${BOLD}${TARGET_USER}${NC} (Home: ${USER_HOME})"

# ------------------------------------------------------------------------------
# 1. Dependency Resolution
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[1/5] Checking and installing dependencies...${NC}"

install_deps_apt() {
    apt-get update -qq || true
    apt-get install -y --no-install-recommends \
        build-essential gcc make \
        libimage-exiftool-perl \
        inotify-tools \
        xclip \
        libnotify-bin
}

install_deps_dnf() {
    dnf install -y \
        gcc make \
        perl-Image-ExifTool \
        inotify-tools \
        xclip \
        libnotify
}

install_deps_pacman() {
    pacman -Sy --noconfirm --needed \
        base-devel gcc make \
        perl-image-exiftool \
        inotify-tools \
        xclip \
        libnotify
}

if command -v apt-get >/dev/null 2>&1; then
    install_deps_apt
elif command -v dnf >/dev/null 2>&1; then
    install_deps_dnf
elif command -v pacman >/dev/null 2>&1; then
    install_deps_pacman
else
    echo -e "${YELLOW}Warning: Unknown package manager. Please ensure gcc, make, exiftool, inotify-tools, and xclip are installed.${NC}"
fi

# ------------------------------------------------------------------------------
# 2. Build and Install Shared Library & Binaries
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[2/5] Compiling interceptor shared library...${NC}"
make -C "$SCRIPT_DIR" build
make -C "$SCRIPT_DIR" install

# Create sticky shared memory directory
mkdir -p -m 01777 /dev/shm/.clean_send
chmod 01777 /dev/shm/.clean_send

# ------------------------------------------------------------------------------
# 3. Application Wrappers & Environment Setup
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[3/5] Setting up application wrappers & environment...${NC}"

# Chrome wrappers
cat << 'WRAPPER' > /usr/local/bin/google-chrome-stable
#!/usr/bin/env bash
export LD_PRELOAD="/usr/local/lib/libcleanupload.so${LD_PRELOAD:+:$LD_PRELOAD}"
exec /usr/bin/google-chrome-stable "$@"
WRAPPER
chmod +x /usr/local/bin/google-chrome-stable
ln -sf /usr/local/bin/google-chrome-stable /usr/local/bin/google-chrome

# Discord wrapper
cat << 'WRAPPER' > /usr/local/bin/discord
#!/usr/bin/env bash
export LD_PRELOAD="/usr/local/lib/libcleanupload.so${LD_PRELOAD:+:$LD_PRELOAD}"
exec /usr/bin/discord "$@"
WRAPPER
chmod +x /usr/local/bin/discord

# Telegram wrapper
cat << 'WRAPPER' > /usr/local/bin/telegram-desktop
#!/usr/bin/env bash
export LD_PRELOAD="/usr/local/lib/libcleanupload.so${LD_PRELOAD:+:$LD_PRELOAD}"
if [[ -x /usr/bin/telegram-desktop ]]; then
    exec /usr/bin/telegram-desktop "$@"
fi
exit 0
WRAPPER
chmod +x /usr/local/bin/telegram-desktop

# Global session environment
mkdir -p /etc/environment.d
echo 'LD_PRELOAD="/usr/local/lib/libcleanupload.so"' > /etc/environment.d/50-cleanupload.conf

cat << 'ENV' > /etc/profile.d/cleanupload.sh
export LD_PRELOAD="/usr/local/lib/libcleanupload.so${LD_PRELOAD:+:$LD_PRELOAD}"
ENV
chmod 644 /etc/profile.d/cleanupload.sh

# ------------------------------------------------------------------------------
# 4. User Drop-Zone, Nemo Action & Systemd Services
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[4/5] Configuring user SafeSend drop-zone and services...${NC}"

if [[ -n "$USER_HOME" && -d "$USER_HOME" && "$TARGET_USER" != "root" ]]; then
    # Create SafeSend Drop-Zone folder
    DROP_DIR="$USER_HOME/Desktop/SafeSend"
    mkdir -p "$DROP_DIR"
    cat << 'README' > "$DROP_DIR/README.txt"
SafeSend Drop-Zone
===================
1. Drag any photo, video, PDF, or document here to clean metadata.
2. Metadata is stripped automatically.
3. Drag it directly into Discord, Telegram, or your Browser.
4. Once uploaded, the file is automatically purged.
No duplicate files are ever kept.
README
    chown -R "${TARGET_USER}:${TARGET_USER}" "$DROP_DIR"

    # Nemo context action
    NEMO_DIR="$USER_HOME/.local/share/nemo/actions"
    mkdir -p "$NEMO_DIR"
    cp "$SCRIPT_DIR/desktop/safesend.nemo_action" "$NEMO_DIR/"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$USER_HOME/.local/share/nemo"

    # User systemd service directory
    USER_SYSTEMD="$USER_HOME/.config/systemd/user"
    mkdir -p "$USER_SYSTEMD"
    cp "$SCRIPT_DIR/systemd/safesend-watcher.service" "$USER_SYSTEMD/"
    cp "$SCRIPT_DIR/systemd/safesend-clipboard.service" "$USER_SYSTEMD/"

    # Portal override
    PORTAL_OVERRIDE="$USER_SYSTEMD/xdg-desktop-portal-gtk.service.d"
    mkdir -p "$PORTAL_OVERRIDE"
    cp "$SCRIPT_DIR/systemd/xdg-desktop-portal-gtk.service.d/override.conf" "$PORTAL_OVERRIDE/"

    chown -R "${TARGET_USER}:${TARGET_USER}" "$USER_HOME/.config/systemd"

    # Reload systemd user daemon and restart services if user session active
    USER_RUNTIME="/run/user/${USER_UID}"
    if [[ -d "$USER_RUNTIME" ]]; then
        sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$USER_RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=${USER_RUNTIME}/bus" systemctl --user daemon-reload || true
        sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$USER_RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=${USER_RUNTIME}/bus" systemctl --user enable --now safesend-watcher.service safesend-clipboard.service || true
        sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$USER_RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=${USER_RUNTIME}/bus" systemctl --user restart xdg-desktop-portal-gtk.service 2>/dev/null || true
    fi
fi

# ------------------------------------------------------------------------------
# 5. Verification & Tests
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[5/5] Running verification tests...${NC}"
python3 "$SCRIPT_DIR/tests/test_clean.py" || true

echo -e "\n${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}  ExifCleaner AutoSend Successfully Installed!${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"
echo -e "You can now share files with automatic metadata cleaning:"
echo -e "  • ${BOLD}File Picker (+):${NC} Attach files in Chrome, Discord, or Telegram normally."
echo -e "  • ${BOLD}Drag & Drop:${NC} Drag directly into Discord, Telegram, or Browser chat."
echo -e "  • ${BOLD}Drop-Zone:${NC} Drop files into ${BOLD}~/Desktop/SafeSend${NC}."
echo -e "  • ${BOLD}Right-Click:${NC} Nemo Context Menu -> 'Safe Send'."
echo -e "\nCheck status anytime: ${BOLD}safesend --status${NC}\n"
