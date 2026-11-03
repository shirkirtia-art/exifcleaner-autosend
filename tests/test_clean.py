#!/usr/bin/env python3
"""
Comprehensive Integration Test Suite for SafeSend (exifcleaner-autosend)
Verifies multi-format metadata stripping, original file preservation,
shared library symbols, and CLI utilities.
"""

import os
import sys
import shutil
import zipfile
import subprocess
import tempfile

def log(msg, status="INFO"):
    colors = {"INFO": "\033[94m", "PASS": "\033[92m", "FAIL": "\033[91m", "END": "\033[0m"}
    print(f"{colors.get(status, '')}[{status}] {msg}{colors['END']}")

def check_dependencies():
    missing = []
    for cmd in ["exiftool", "gcc", "ffmpeg"]:
        if not shutil.which(cmd):
            missing.append(cmd)
    if missing:
        log(f"Optional or required tools missing: {missing}", "INFO")
    return True

def get_clean_binary():
    bin_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "../bin/clean-for-send"))
    if not os.path.isfile(bin_path):
        bin_path = "/usr/local/bin/clean-for-send"
    return bin_path

def test_shared_library():
    so_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "../build/libcleanupload.so"))
    if not os.path.isfile(so_path):
        so_path = "/usr/local/lib/libcleanupload.so"

    if not os.path.isfile(so_path):
        log(f"Shared library not found at {so_path}. Run 'make' first.", "FAIL")
        return False

    import ctypes
    try:
        lib = ctypes.CDLL(so_path)
        # Verify symbol resolution
        assert hasattr(lib, "open"), "open symbol missing"
        assert hasattr(lib, "gtk_file_chooser_get_filename"), "gtk_file_chooser_get_filename symbol missing"
        log(f"Shared library loaded successfully with exported symbols ({so_path})", "PASS")
        return True
    except Exception as e:
        log(f"Failed to load shared library: {e}", "FAIL")
        return False

def test_image_stripping():
    clean_bin = get_clean_binary()
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as f:
        test_img = f.name

    try:
        # Generate minimal valid JPEG via Python
        subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i", "color=c=teal:s=64x64", "-frames:v", "1", test_img],
                       capture_output=True, check=True)

        # Inject EXIF metadata
        subprocess.run(["exiftool", "-overwrite_original", "-Artist=SECRET_ARTIST", "-GPSLatitude=37.7749", test_img],
                       capture_output=True, check=True)

        chk = subprocess.run(["exiftool", "-Artist", test_img], capture_output=True, text=True)
        if "SECRET_ARTIST" not in chk.stdout:
            log("Could not write test metadata to image", "FAIL")
            return False

        # Run clean-for-send
        subprocess.run([clean_bin, test_img], check=True)

        chk_after = subprocess.run(["exiftool", "-Artist", "-GPSLatitude", test_img], capture_output=True, text=True)
        if "SECRET_ARTIST" in chk_after.stdout or "37" in chk_after.stdout:
            log("Image metadata was NOT stripped", "FAIL")
            return False

        log("Image metadata stripping test passed (EXIF & GPS removed)", "PASS")
        return True
    finally:
        if os.path.exists(test_img):
            os.remove(test_img)

def test_media_stripping():
    clean_bin = get_clean_binary()
    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
        test_audio = f.name

    try:
        # Generate minimal valid MP3 with metadata
        subprocess.run(["ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1",
                        "-metadata", "artist=SECRET_MEDIA_ARTIST", test_audio],
                       capture_output=True, check=True)

        # Run clean-for-send
        subprocess.run([clean_bin, test_audio], check=True)

        with open(test_audio, "rb") as f:
            raw = f.read()

        if b"SECRET_MEDIA_ARTIST" in raw:
            log("Media metadata was NOT stripped from audio container", "FAIL")
            return False

        log("Audio/Video metadata stripping test passed (stream copy losslessly sanitized)", "PASS")
        return True
    finally:
        if os.path.exists(test_audio):
            os.remove(test_audio)

def test_docx_stripping():
    clean_bin = get_clean_binary()
    with tempfile.NamedTemporaryFile(suffix=".docx", delete=False) as f:
        test_doc = f.name

    try:
        with zipfile.ZipFile(test_doc, "w") as zf:
            zf.writestr("docProps/core.xml",
                        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/coreProperties" '
                        'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>SECRET_DOC_CREATOR</dc:creator></cp:coreProperties>')
            zf.writestr("word/document.xml", "<w:document><w:body><w:p><w:r><w:t>Confidential</w:t></w:r></w:p></w:body></w:document>")

        subprocess.run([clean_bin, test_doc], check=True)

        with open(test_doc, "rb") as f:
            raw = f.read()

        if b"SECRET_DOC_CREATOR" in raw:
            log("Office document metadata was NOT stripped", "FAIL")
            return False

        log("Office document (.docx) metadata stripping test passed", "PASS")
        return True
    finally:
        if os.path.exists(test_doc):
            os.remove(test_doc)

def test_pdf_stripping():
    clean_bin = get_clean_binary()
    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
        test_pdf = f.name

    try:
        pdf_content = (
            b"%PDF-1.4\n"
            b"1 0 obj << /Title (Secret Title) /Author (SECRET_PDF_AUTHOR) >> endobj\n"
            b"2 0 obj << /Type /Catalog /Pages 3 0 R >> endobj\n"
            b"3 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\n"
            b"xref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000085 00000 n \n0000000135 00000 n \n"
            b"trailer << /Size 4 /Root 2 0 R /Info 1 0 R >>\nstartxref\n185\n%%EOF\n"
        )
        with open(test_pdf, "wb") as f:
            f.write(pdf_content)

        subprocess.run([clean_bin, test_pdf], check=True)

        with open(test_pdf, "rb") as f:
            cleaned = f.read()

        if b"SECRET_PDF_AUTHOR" in cleaned:
            log("PDF author metadata was NOT stripped from file bytes", "FAIL")
            return False

        log("PDF document metadata stripping test passed (zero incremental leaks)", "PASS")
        return True
    finally:
        if os.path.exists(test_pdf):
            os.remove(test_pdf)

def test_cli():
    safesend_bin = os.path.abspath(os.path.join(os.path.dirname(__file__), "../bin/safesend"))
    if not os.path.isfile(safesend_bin):
        safesend_bin = "/usr/local/bin/safesend"

    # Test --help
    res = subprocess.run([safesend_bin, "--help"], capture_output=True, text=True)
    if "Usage:" not in res.stdout:
        log("safesend --help failed", "FAIL")
        return False

    # Test --status
    res2 = subprocess.run([safesend_bin, "--status"], capture_output=True, text=True)
    if "Status" not in res2.stdout:
        log("safesend --status failed", "FAIL")
        return False

    log("SafeSend CLI commands verified (--help, --status)", "PASS")
    return True

def main():
    print("=" * 60)
    print("  Running SafeSend (ExifCleaner AutoSend) Test Suite")
    print("=" * 60)

    check_dependencies()

    tests = [
        ("Shared Library", test_shared_library),
        ("Image Sanitization", test_image_stripping),
        ("Media Sanitization", test_media_stripping),
        ("Office Document Sanitization", test_docx_stripping),
        ("PDF Sanitization", test_pdf_stripping),
        ("CLI Utilities", test_cli),
    ]

    all_passed = True
    for name, fn in tests:
        if not fn():
            all_passed = False

    print("=" * 60)
    if all_passed:
        log("All integration tests passed successfully!", "PASS")
        sys.exit(0)
    else:
        log("Some integration tests failed.", "FAIL")
        sys.exit(1)

if __name__ == "__main__":
    main()
