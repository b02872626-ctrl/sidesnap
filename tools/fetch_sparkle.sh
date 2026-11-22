#!/bin/bash
# Downloads the pinned Sparkle release into Vendor/ (not kept in git) and
# checks its fingerprint, so every build uses exactly the same updater.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
DIR="Vendor/Sparkle-$VERSION"
[ -d "$DIR/Sparkle.framework" ] && exit 0
echo "Downloading Sparkle $VERSION..."
mkdir -p "$DIR"
curl -sSL -o "$DIR/Sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
echo "$SHA256  $DIR/Sparkle.tar.xz" | shasum -a 256 -c - >/dev/null \
    || { echo "ERROR: Sparkle download doesn't match the expected fingerprint."; rm -rf "$DIR"; exit 1; }
tar -xf "$DIR/Sparkle.tar.xz" -C "$DIR" && rm "$DIR/Sparkle.tar.xz"
