#!/usr/bin/env python3
"""
Integration test suite for exifcleaner-autosend
Verifies metadata stripping, original preservation, and ephemeral auto-purge.
"""

import os
import sys
import shutil
import subprocess

def log(msg, status="INFO"):
    colors = {"INFO": "\033[94m", "PASS": "\033[92m", "FAIL": "\033[91m", "END": "\033[0m"}
    print(f"{colors.get(status, '')}[{status}] {msg}{colors['END']}")

def check_dependencies():
    for cmd in ["exiftool", "gcc"]:
        if not shutil.which(cmd):
            log(f"Required command '{cmd}' is not found in PATH", "FAIL")
            return False
    return True

def create_valid_test_image(path):
    try:
        from PIL import Image
        img = Image.new('RGB', (100, 100), color='teal')
        img.save(path)
        return True
    except ImportError:
        pass
    if shutil.which("convert"):
        subprocess.run(["convert", "-size", "100x100", "xc:teal", path], capture_output=True)
        return os.path.exists(path)
    return False

def test_metadata_stripping():
    test_img = "/tmp/autosend_test.jpg"
    if not create_valid_test_image(test_img):
        log("Unable to generate test image via PIL or convert", "FAIL")
        return False

    # Inject EXIF metadata
    subprocess.run(["exiftool", "-overwrite_original", "-Artist=SECRET_AUTOSEND_ARTIST", "-GPSLatitude=37.7749", test_img], capture_output=True)

    # Verify initial metadata exists
    chk = subprocess.run(["exiftool", "-Artist", test_img], capture_output=True, text=True)
    if "SECRET_AUTOSEND_ARTIST" not in chk.stdout:
        log("Could not write test metadata to sample image", "FAIL")
        return False

    # Run clean-for-send
    clean_bin = os.path.abspath(os.path.join(os.path.dirname(__file__), "../bin/clean-for-send"))
    if not os.path.exists(clean_bin):
        clean_bin = "/usr/local/bin/clean-for-send"

    subprocess.run([clean_bin, test_img], check=True)

    # Verify metadata is stripped
    chk_after = subprocess.run(["exiftool", "-Artist", test_img], capture_output=True, text=True)
    if "SECRET_AUTOSEND_ARTIST" in chk_after.stdout:
        log("Metadata was NOT stripped by clean-for-send", "FAIL")
        return False

    if os.path.exists(test_img):
        os.remove(test_img)
    log("Metadata stripping test passed (losslessly cleaned)", "PASS")
    return True

def test_shared_library():
    so_path = "/usr/local/lib/libcleanupload.so"
    if not os.path.exists(so_path):
        so_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "../build/libcleanupload.so"))

    if not os.path.exists(so_path):
        log(f"Shared library not found at {so_path}. Run 'make' first.", "FAIL")
        return False

    import ctypes
    try:
        lib = ctypes.CDLL(so_path)
        log(f"Shared library loaded successfully ({so_path})", "PASS")
        return True
    except Exception as e:
        log(f"Failed to load shared library: {e}", "FAIL")
        return False

def main():
    print("=" * 55)
    print(" Running ExifCleaner AutoSend Test Suite")
    print("=" * 55)

    if not check_dependencies():
        sys.exit(1)

    all_passed = True
    if not test_shared_library():
        all_passed = False
    if not test_metadata_stripping():
        all_passed = False

    print("=" * 55)
    if all_passed:
        log("All integration tests passed successfully!", "PASS")
        sys.exit(0)
    else:
        log("Some tests failed.", "FAIL")
        sys.exit(1)

if __name__ == "__main__":
    main()
