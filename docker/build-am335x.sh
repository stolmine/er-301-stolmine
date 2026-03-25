#!/bin/bash
set -e

echo "=== Building ER-301 firmware + TXo mod for AM335x ==="

cd /er-301

echo "--- Building firmware (kernel + core + teletype + txo) ---"
make firmware ARCH=am335x

echo "=== Build complete ==="
echo "Outputs:"
ls -lh release/am335x/er-301-v*.zip 2>/dev/null
unzip -l release/am335x/er-301-v*.zip 2>/dev/null
