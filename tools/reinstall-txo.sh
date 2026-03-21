#!/bin/bash
# Clean reinstall of TXo package for the emulator
set -e

cd "$(dirname "$0")/.."

echo "Cleaning old TXo installation..."
rm -rf ~/.od/rear/v0.7/libs/txo/ 2>/dev/null
rm -f ~/.od/rear/v0.7/meta/packages/txo.db 2>/dev/null
rm -f ~/.od/front/ER-301/packages/txo-*.pkg 2>/dev/null
rm -f ~/.od/rear/txo-*.pkg 2>/dev/null
rm -f /tmp/er301-txo-monitor 2>/dev/null

# Remove txo from packages.db
if [ -f ~/.od/rear/v0.7/meta/packages.db ]; then
  sed -i '' '/txo/d' ~/.od/rear/v0.7/meta/packages.db
fi

echo "Removing old build artifacts..."
rm -f testing/darwin/mods/txo-*.pkg 2>/dev/null

echo "Building TXo mod..."
make txo-clean 2>/dev/null
make txo

echo "Installing..."
PKG=$(ls testing/darwin/mods/txo-*.pkg 2>/dev/null | head -1)
if [ -z "$PKG" ]; then
  echo "ERROR: No .pkg found"
  exit 1
fi
cp "$PKG" ~/.od/rear/
echo "Installed: $(basename $PKG)"
echo "Restart the emulator."
