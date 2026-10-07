#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
if [[ -f Vendor/Sparkle/.verified-version && "$(cat Vendor/Sparkle/.verified-version)" == "$VERSION" && -d Vendor/Sparkle/Sparkle.framework ]]; then
    exit 0
fi
DOWNLOAD_DIR=$(mktemp -d)
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
curl --fail --location --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$DOWNLOAD_DIR/Sparkle.tar.xz"
printf '%s  %s\n' "$SHA256" "$DOWNLOAD_DIR/Sparkle.tar.xz" | shasum -a 256 -c -
mkdir -p Vendor/Sparkle
tar -xJf "$DOWNLOAD_DIR/Sparkle.tar.xz" -C Vendor/Sparkle
printf '%s' "$VERSION" > Vendor/Sparkle/.verified-version
