# ExifCleaner AutoSend (SafeSend)

> **Zero-duplicate, on-the-fly metadata stripping and auto-purging for Linux uploads.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-orange.svg)](#)
[![Zero Duplicate Files](https://img.shields.io/badge/Duplicates-Zero%20Leftovers-brightgreen.svg)](#)
[![Privacy First](https://img.shields.io/badge/Privacy-100%25%20Local-success.svg)](#)

---

## The Problem
When sharing photos, documents, or videos on Discord, Telegram, or through web browsers, files often leak sensitive metadata:
- **GPS Coordinates** (exact home, work, or vacation latitude & longitude)
- **Device & Camera Serial Numbers**
- **Date, Time & Software Versions**
- **Author, Organization, Document Revision History**

Conventional metadata cleaners force you to generate a separate cleaned copy (`photo_clean.jpg` or `contract(1).pdf`), cluttering your disk with duplicate files ("double double files") that you have to remember to delete later.

## The Solution
**ExifCleaner AutoSend** automatically intercepts uploads in **Google Chrome, Discord, Telegram, Firefox, and web-based sharing platforms**:
1. When you select or drag-and-drop a file to send, it transparently creates an **ephemeral copy in RAM** (`/dev/shm`).
2. It strips all metadata losslessly using ExifCleaner's engine before the app transmits it.
3. The uploading app streams the sanitized bytes to the server.
4. An **event-driven inotify watcher** monitors when the file descriptor is closed by the uploading application and **automatically purges the temporary file**.
5. Your **original file remains 100% untouched**, and **zero duplicate files** are left behind!

```
[ User Selects / Drags File ]
              │
              ▼
    [ libcleanupload.so ] ───► Intercepts open() / file chooser
              │
              ├──► Copies to ephemeral RAM (/dev/shm/.clean_send)
              ├──► clean-for-send strips EXIF/GPS/Author metadata
              │
              ▼
[ Application Reads & Uploads Clean File ]
              │
              ▼
   [ inotify: IN_CLOSE_NOWRITE ]
              │
              ▼
  [ Automatically Purged from RAM ] ──► Zero duplicate files left!
```

---

## Features

- **Universal Application Support:** Works with Chrome, Chromium, Brave, Firefox, Discord (Electron), Telegram Desktop, and web-based PDF/file sharing sites.
- **Both File Dialogs & Drag-and-Drop:** Intercepts standard GTK/Portal file pickers as well as direct drag-and-drop file transfers.
- **Zero Duplicate Files:** Never generates persistent clutter like `file_clean.png`. Cleaned files reside in memory and self-destruct once uploaded.
- **Originals Preserved:** Your personal photos and documents on disk are never altered or damaged.
- **0% Idle CPU Usage:** Event-driven architecture using Linux kernel `inotify`; completely dormant until you initiate an upload.
- **Desktop Drop-Zone:** Includes a `~/Desktop/SafeSend` folder for drag-and-drop sharing with automatic 3-minute self-destruct.
- **Automated Clipboard & Screenshot Sanitization:** Wakes up instantly when you take a screenshot (e.g. PrtScn) or copy an image/file, stripping all metadata in-place before you hit paste (`Ctrl+V`).
- **Nemo Context Menu:** Right-click any file in Nemo &rarr; *"Safe Send (Strip Metadata & Copy)"* to immediately paste sanitized files via `Ctrl+V`.

---

## Supported Formats

| Category | File Extensions |
| :--- | :--- |
| **Images** | `.jpg`, `.jpeg`, `.png`, `.webp`, `.heic`, `.heif`, `.avif`, `.tiff`, `.tif`, `.gif`, `.bmp`, `.svg` |
| **Documents** | `.pdf`, `.docx`, `.xlsx`, `.pptx`, `.doc`, `.xls`, `.ppt`, `.odt`, `.ods`, `.odp` |
| **Media** | `.mp4`, `.m4v`, `.mov`, `.mkv`, `.avi`, `.webm`, `.mp3`, `.wav`, `.ogg`, `.flac` |

---

## Quick Installation

### ⚡ Option 1: Fast One-Line Install (Recommended)
Run this single command in your Linux terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/shirkirtia-art/exifcleaner-autosend/main/install.sh | bash
```

### 📦 Option 2: Clone & Install Manually

```bash
git clone https://github.com/shirkirtia-art/exifcleaner-autosend.git
cd exifcleaner-autosend
sudo ./install.sh
```

The installer automatically:
1. Installs dependencies (`exiftool`, `inotify-tools`, `gcc`, `make`, `xclip`).
2. Compiles the high-performance `libcleanupload.so` shared library.
3. Configures application wrappers and XDG Desktop Portal overrides.
4. Sets up the `~/Desktop/SafeSend` drop-zone and Nemo right-click action.
5. Runs verification tests to confirm functionality.

### Manual Installation via Make

```bash
make
sudo make install
```

---

## How to Use

### 1. Normal File Upload (Fully Automatic)
Click **Attach**, **Upload**, or the `+` paperclip in Discord, Chrome, Telegram, or any browser uploader. Select your file as usual. The cleaner runs in the background, delivers the clean file to the server, and purges the temporary copy when finished.

### 2. Direct Drag & Drop
Drag any photo or document from your file manager directly into your Discord channel or browser chat window. The interceptor catches the read call, cleans the file in RAM, and uploads without leaving duplicates.

### 3. Desktop SafeSend Drop-Zone (`~/Desktop/SafeSend`)
Drag files into the `SafeSend` folder on your desktop. The file is instantly cleaned in-place. Drag it from `SafeSend` into your app to send. Once uploaded, the file in `SafeSend` automatically deletes itself!

### 4. Screenshots & Clipboard Copy-Paste (Fully Automatic)
Take a screenshot using your preferred shortcut (e.g., <kbd>PrtScn</kbd>) or copy an image from any app. The clipboard daemon immediately intercepts and strips EXIF/GPS metadata from the clipboard image in RAM. When you press <kbd>Ctrl</kbd>+<kbd>V</kbd> in Discord, Telegram, or web chat, it pastes the clean, sanitized image!

Similarly, if you copy any image or document file in your file manager (<kbd>Ctrl</kbd>+<kbd>C</kbd>), the clipboard automatically stages an ephemeral sanitized copy so pasting into Discord or Telegram sends the clean file without duplicates.

### 5. Right-Click Context Menu (Nemo)
Right-click any file &rarr; select **"Safe Send (Strip Metadata & Copy for Upload)"**. The cleaned copy is placed on your clipboard. Press <kbd>Ctrl</kbd>+<kbd>V</kbd> to paste it into any chat.

### 6. Command-Line Utility
Check service status or clean files from your terminal:

```bash
# Check status of all components
safesend --status

# Clean a file in-place
safesend --clean sample.jpg

# Prepare an ephemeral cleaned file and copy to clipboard
safesend --send report.pdf
```

---

## Architecture & Security

- **Ephemeral Storage in RAM:** Ephemeral files are written exclusively to `/dev/shm/.clean_send/` (a tmpfs RAM filesystem). They never cause SSD wear and are wiped on reboot even if unlinked.
- **Strict Permissions:** Temporary session subdirectories are created with `0700` permissions owned strictly by the active user. Other local users cannot read in-flight files.
- **Clean Fallback:** If any unexpected error occurs, the system safely falls back to standard behavior without crashing your applications.

---

## Uninstallation

To remove all components and restore original configurations:

```bash
curl -fsSL https://raw.githubusercontent.com/shirkirtia-art/exifcleaner-autosend/main/uninstall.sh | bash
```

Or from the cloned directory:

```bash
sudo ./uninstall.sh
```

Or:

```bash
sudo make uninstall
```

---

## License

Released under the [MIT License](LICENSE).
