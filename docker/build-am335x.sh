#!/bin/bash
set -e

echo "=== Building ER-301 firmware + TXo mod for AM335x ==="

cd /er-301

echo "--- Building firmware ---"
make firmware ARCH=am335x

echo "--- Building core mod ---"
make core ARCH=am335x

echo "--- Building TXo mod ---"
make txo ARCH=am335x

echo "=== Build complete ==="
echo "Outputs:"
ls -la testing/am335x/mods/txo-*.pkg 2>/dev/null
ls -la release/am335x/mods/txo-*.pkg 2>/dev/null
find . -name 'kernel.bin' -path '*/am335x/*' 2>/dev/null
