#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Cannonball LL RMK Firmware Build Script ==="

# Check / install required cargo tools
if ! command -v flip-link >/dev/null 2>&1; then
    echo "Installing flip-link..."
    cargo install flip-link
fi

if ! cargo objcopy --help >/dev/null 2>&1; then
    echo "Installing cargo-binutils..."
    cargo install cargo-binutils
fi

if ! command -v cargo-hex-to-uf2 >/dev/null 2>&1; then
    echo "Installing cargo-hex-to-uf2..."
    cargo install cargo-hex-to-uf2
fi

echo "===> Building standard variant (rmk-cannonball-ll.uf2)..."
cargo objcopy --release -- -O ihex rmk-cannonball-ll.hex
cargo hex-to-uf2 --input-path rmk-cannonball-ll.hex --output-path rmk-cannonball-ll.uf2 --family nrf52840

echo "===> Building sensor-rotated-180 variant (rmk-cannonball-ll-sensor-rotated-180.uf2)..."
cargo objcopy --release --features sensor-rotated-180 -- -O ihex rmk-cannonball-ll-sensor-rotated-180.hex
cargo hex-to-uf2 --input-path rmk-cannonball-ll-sensor-rotated-180.hex --output-path rmk-cannonball-ll-sensor-rotated-180.uf2 --family nrf52840

echo "===> Build completed successfully!"
ls -lh *.uf2
