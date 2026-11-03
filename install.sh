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
        ffmpeg \
        inotify-tools \
        xclip \
        libnotify-bin \
        python3-gi \
        gir1.2-gtk-3.0
}

install_deps_dnf() {
    dnf install -y \
        gcc make \
        perl-Image-ExifTool \
        ffmpeg \
        inotify-tools \
        xclip \
        libnotify \
        python3-gobject \
        gtk3
}

install_deps_pacman() {
    pacman -Sy --noconfirm --needed \
        base-devel gcc make \
        perl-image-exiftool \
        ffmpeg \
        inotify-tools \
        xclip \
        libnotify \
        python-gobject \
        gtk3
}

if command -v apt-get >/dev/null 2>&1; then
    install_deps_apt
elif command -v dnf >/dev/null 2>&1; then
    install_deps_dnf
elif command -v pacman >/dev/null 2>&1; then
    install_deps_pacman
else
    echo -e "${YELLOW}Warning: Unknown package manager. Please ensure gcc, make, exiftool, ffmpeg, inotify-tools, python3-gi, and xclip are installed.${NC}"
fi

# ------------------------------------------------------------------------------
# 2. Build and Install Shared Library & Binaries
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[2/5] Compiling interceptor shared library and installing binaries...${NC}"
chmod +x "$SCRIPT_DIR/bin/"*
make -C "$SCRIPT_DIR" build
make -C "$SCRIPT_DIR" install

# Create sticky shared memory directory
mkdir -p -m 01777 /dev/shm/.clean_send
chmod 01777 /dev/shm/.clean_send

# Remove legacy global profile/environment preloads to protect system stability
rm -f /etc/environment.d/50-cleanupload.conf
rm -f /etc/profile.d/cleanupload.sh

# ------------------------------------------------------------------------------
# 3. Application Wrappers (Targeted & Dynamic)
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[3/5] Setting up application wrappers...${NC}"

# Chrome / Chromium wrapper
cat << 'WRAPPER' > /usr/local/bin/google-chrome-stable
#!/usr/bin/env bash
REAL_BIN=""
for path in /usr/bin/google-chrome-stable /opt/google/chrome/google-chrome /usr/bin/google-chrome /usr/bin/chromium /usr/bin/chromium-browser; do
    if [[ -x "$path" && "$path" != "/usr/local/bin/google-chrome-stable" ]]; then
        REAL_BIN="$path"
        break
    fi
done
if [[ -n "$REAL_BIN" ]]; then
    export LD_PRELOAD="/usr/local/lib/libcleanupload.so${LD_PRELOAD:+:$LD_PRELOAD}"
    exec "$REAL_BIN" "$@"
fi
exit 1
WRAPPER
chmod 755 /usr/local/bin/google-chrome-stable
ln -sf /usr/local/bin/google-chrome-stable /usr/local/bin/google-chrome

# Discord wrapper
cat << 'WRAPPER' > /usr/local/bin/discord
#!/usr/bin/env bash
REAL_BIN=""
for path in /usr/bin/discord /opt/discord/Discord /usr/share/discord/Discord; do
    if [[ -x "$path" && "$path" != "/usr/local/bin/discord" ]]; then
        REAL_BIN="$path"
        break
    fi
done
if [[ -n "$REAL_BIN" ]]; then
    export LD_PRELOAD="/usr/local/lib/libcleanupload.so${LD_PRELOAD:+:$LD_PRELOAD}"
    exec "$REAL_BIN" "$@"
fi
exit 1
WRAPPER
chmod 755 /usr/local/bin/discord

# Telegram wrapper
cat << 'WRAPPER' > /usr/local/bin/telegram-desktop
#!/usr/bin/env bash
REAL_BIN=""
for path in /usr/bin/telegram-desktop /opt/telegram/Telegram /opt/Telegram/Telegram; do
    if [[ -x "$path" && "$path" != "/usr/local/bin/telegram-desktop" ]]; then
        REAL_BIN="$path"
        break
    fi
done
if [[ -n "$REAL_BIN" ]]; then
    export LD_PRELOAD="/usr/local/lib/libcleanupload.so${LD_PRELOAD:+:$LD_PRELOAD}"
    exec "$REAL_BIN" "$@"
fi
exit 1
WRAPPER
chmod 755 /usr/local/bin/telegram-desktop

# Install Desktop Application Entry
if [[ -d /usr/share/applications ]]; then
    install -m 644 "$SCRIPT_DIR/desktop/SafeSend.desktop" /usr/share/applications/
fi

# ------------------------------------------------------------------------------
# 4. User Drop-Zone, File Manager Actions & Systemd Services
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[4/5] Configuring user SafeSend drop-zone and services...${NC}"

if [[ -n "$USER_HOME" && -d "$USER_HOME" && "$TARGET_USER" != "root" ]]; then
    # Create SafeSend Drop-Zone folder
    DROP_DIR="$USER_HOME/Desktop/SafeSend"
    mkdir -p "$DROP_DIR"
    cat << 'README' > "$DROP_DIR/README.txt"
SafeSend Drop-Zone
===================
1. Drag any photo, video, PDF, or document here.
2. Metadata (GPS, camera serials, author, company) is stripped in-place automatically.
3. Drag it directly into Discord, Telegram, or your Browser.
Your files remain available on your desktop until you choose to move or delete them.
README
    chown -R "${TARGET_USER}:${TARGET_USER}" "$DROP_DIR"

    # Nemo context action (Cinnamon)
    NEMO_DIR="$USER_HOME/.local/share/nemo/actions"
    mkdir -p "$NEMO_DIR"
    cp "$SCRIPT_DIR/desktop/safesend.nemo_action" "$NEMO_DIR/"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$USER_HOME/.local/share/nemo"

    # Nautilus context script (GNOME)
    NAUTILUS_DIR="$USER_HOME/.local/share/nautilus/scripts"
    mkdir -p "$NAUTILUS_DIR"
    cp "$SCRIPT_DIR/desktop/safesend.nautilus_script" "$NAUTILUS_DIR/Safe Send (Strip Metadata & Copy)"
    chmod +x "$NAUTILUS_DIR/Safe Send (Strip Metadata & Copy)"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$USER_HOME/.local/share/nautilus"

    # Dolphin context menu (KDE Plasma)
    DOLPHIN_DIR="$USER_HOME/.local/share/kio/servicemenus"
    mkdir -p "$DOLPHIN_DIR"
    cp "$SCRIPT_DIR/desktop/safesend.dolphin_servicemenu" "$DOLPHIN_DIR/safesend.desktop"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$USER_HOME/.local/share/kio"

    # User systemd service directory
    USER_SYSTEMD="$USER_HOME/.config/systemd/user"
    mkdir -p "$USER_SYSTEMD"
    cp "$SCRIPT_DIR/systemd/safesend-watcher.service" "$USER_SYSTEMD/"
    cp "$SCRIPT_DIR/systemd/safesend-clipboard.service" "$USER_SYSTEMD/"

    # Portal override (hooks GTK file pickers for all native, Flatpak & Snap apps)
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
python3 "$SCRIPT_DIR/tests/test_clean.py"

echo -e "\n${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}  SafeSend Successfully Installed!${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"
echo -e "You can now share files with automatic, zero-duplicate metadata cleaning:"
echo -e "  • ${BOLD}File Picker (+):${NC} Attach files in Chrome, Discord, or Telegram normally."
echo -e "  • ${BOLD}Drag & Drop:${NC} Drag directly into Discord, Telegram, or Browser chat."
echo -e "  • ${BOLD}Drop-Zone:${NC} Drop files into ${BOLD}~/Desktop/SafeSend${NC}."
echo -e "  • ${BOLD}Right-Click:${NC} Context Menu -> 'Safe Send (Strip Metadata & Copy)'."
echo -e "\nCheck status anytime: ${BOLD}safesend --status${NC}\n"
