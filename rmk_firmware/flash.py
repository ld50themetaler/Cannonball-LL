#!/usr/bin/env python3
"""Cannonball LL automated firmware flashing script.

1. Sends VIA Bootloader Jump command (0x0B) to Cannonball LL (VID: 0x8884, PID: 0x0919).
2. Waits for XIAO-SENSE / XIAO-BLE mass storage drive to appear.
3. Automatically copies the specified UF2 file to the drive.
"""

import argparse
import os
import shutil
import sys
import time

try:
    import hid
except ImportError:
    hid = None

VID = 0x8884
PID = 0x0919
USAGE_PAGE = 0xFF60
USAGE = 0x61
BOOTLOADER_LABELS = ("XIAO-SENSE", "XIAO-BLE", "NRF52BOOT")


def find_bootloader_drive():
    if sys.platform == "win32":
        import ctypes
        import string

        bitmask = ctypes.cdll.kernel32.GetLogicalDrives()
        for letter in string.ascii_uppercase:
            if bitmask & 1:
                drive = f"{letter}:\\"
                try:
                    vol_name_buf = ctypes.create_unicode_buffer(1024)
                    ctypes.cdll.kernel32.GetVolumeInformationW(
                        ctypes.c_wchar_p(drive),
                        vol_name_buf,
                        ctypes.sizeof(vol_name_buf),
                        None, None, None, None, 0
                    )
                    if vol_name_buf.value in BOOTLOADER_LABELS:
                        return drive
                except Exception:
                    pass
            bitmask >>= 1
    elif sys.platform == "linux":
        media_paths = ["/media", f"/media/{os.environ.get('USER', '')}", "/run/media"]
        for base in media_paths:
            if os.path.exists(base):
                for item in os.listdir(base):
                    if item in BOOTLOADER_LABELS:
                        return os.path.join(base, item)
    return None


def send_via_bootloader_jump():
    if hid is None:
        print("[!] python hid module not installed (`pip install hidapi`).")
        return False

    target_path = None
    for d in hid.enumerate(VID, PID):
        if d.get("usage_page") == USAGE_PAGE and d.get("usage") == USAGE:
            target_path = d["path"]
            break
        elif d.get("interface_number") == 1:
            target_path = d["path"]

    if not target_path:
        devs = hid.enumerate(VID, PID)
        if devs:
            target_path = devs[0]["path"]

    if not target_path:
        return False

    try:
        dev = hid.device()
        dev.open_path(target_path)
        # Windows hidapi requires Report ID (0x00) as the first byte
        report = [0x00, 0x0B] + [0x00] * 31
        dev.write(report)
        dev.close()
        return True
    except Exception as e:
        print(f"[!] HID write failed: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(description="Cannonball LL Firmware Flasher")
    parser.add_argument("uf2", nargs="?", default="rmk-cannonball-ll.uf2", help="Path to .uf2 file")
    parser.add_argument("--timeout", type=int, default=15, help="Timeout in seconds")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    uf2_path = os.path.join(script_dir, args.uf2) if not os.path.isabs(args.uf2) else args.uf2
    if not os.path.exists(uf2_path):
        uf2_path = args.uf2
        if not os.path.exists(uf2_path):
            print(f"[!] Error: UF2 file not found: {args.uf2}")
            sys.exit(1)

    print(f"Target UF2: {uf2_path}")

    drive = find_bootloader_drive()
    if not drive:
        print("Sending bootloader jump command (VIA 0x0B)...")
        if send_via_bootloader_jump():
            print("Successfully sent bootloader jump command.")
        else:
            print("Device not detected via HID or failed to send command.")
            print("If already connected, you can double-click the physical reset button.")

        print("Waiting for bootloader drive to appear...", end="", flush=True)
        for _ in range(args.timeout):
            time.sleep(1)
            drive = find_bootloader_drive()
            if drive:
                print(" Found!")
                break
            print(".", end="", flush=True)
        print()

    if not drive:
        print("[!] Timeout: Bootloader drive not found.")
        sys.exit(1)

    print(f"Target drive: {drive}")
    print(f"Copying {os.path.basename(uf2_path)} to {drive}...")
    dest = os.path.join(drive, os.path.basename(uf2_path))
    shutil.copyfile(uf2_path, dest)
    print("Flashing completed! Cannonball LL is rebooting.")


if __name__ == "__main__":
    main()
