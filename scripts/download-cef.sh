#!/bin/bash
#
# Downloads the CEF (Chromium Embedded Framework) minimal distribution for macOS arm64
# and restructures the framework into a proper deep bundle that Xcode expects.
#
# Usage: ./scripts/download-cef.sh
#
# The framework is placed at chromium/ in the project root.
# This directory is gitignored — run this script after cloning.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROMIUM_DIR="$PROJECT_ROOT/chromium"

# CEF version — update these when upgrading
CEF_VERSION="145.0.27+g4ddda2e+chromium-145.0.7632.117"
CEF_VERSION_URLENCODED="145.0.27%2Bg4ddda2e%2Bchromium-145.0.7632.117"
CEF_PLATFORM="macosarm64"
CEF_DIST_TYPE="minimal"

CEF_DIRNAME="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_${CEF_DIST_TYPE}"
CEF_FILENAME="${CEF_DIRNAME}.tar.bz2"
CEF_URL="https://cef-builds.spotifycdn.com/${CEF_FILENAME}"

TMP_DIR="$PROJECT_ROOT/.tmp"

# Check if already downloaded and restructured
if [ -d "$CHROMIUM_DIR/Release/Chromium Embedded Framework.framework/Versions/A" ]; then
    echo "CEF framework already present at $CHROMIUM_DIR"
    echo "Version: $(cat "$CHROMIUM_DIR/VERSION" 2>/dev/null || echo 'unknown')"
    echo "Delete $CHROMIUM_DIR to re-download."
    exit 0
fi

echo "==> Downloading CEF $CEF_VERSION for macOS arm64..."

mkdir -p "$TMP_DIR"

# Download if not already cached
if [ ! -f "$TMP_DIR/$CEF_FILENAME" ]; then
    curl -L --progress-bar -o "$TMP_DIR/$CEF_FILENAME" "$CEF_URL"
else
    echo "    Using cached download at $TMP_DIR/$CEF_FILENAME"
fi

echo "==> Extracting..."
# Extract to temp dir, then move relevant parts
EXTRACT_DIR="$TMP_DIR/cef_extract"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar -xjf "$TMP_DIR/$CEF_FILENAME" -C "$EXTRACT_DIR"

# Find the extracted directory (name matches the archive minus .tar.bz2)
CEF_EXTRACTED="$EXTRACT_DIR/$CEF_DIRNAME"
if [ ! -d "$CEF_EXTRACTED" ]; then
    # Try URL-encoded version in case tar preserves it differently
    CEF_EXTRACTED=$(find "$EXTRACT_DIR" -maxdepth 1 -type d -name "cef_binary_*" | head -1)
fi

if [ ! -d "$CEF_EXTRACTED" ]; then
    echo "ERROR: Could not find extracted CEF directory in $EXTRACT_DIR"
    ls -la "$EXTRACT_DIR"
    exit 1
fi

echo "==> Installing to $CHROMIUM_DIR..."
rm -rf "$CHROMIUM_DIR"
mkdir -p "$CHROMIUM_DIR"

# Copy the parts we need
cp -R "$CEF_EXTRACTED/include" "$CHROMIUM_DIR/include"
cp -R "$CEF_EXTRACTED/Release" "$CHROMIUM_DIR/Release"
cp "$CEF_EXTRACTED/LICENSE.txt" "$CHROMIUM_DIR/LICENSE.txt"
cp "$CEF_EXTRACTED/README.txt" "$CHROMIUM_DIR/README.txt"

# Write version file
echo "$CEF_VERSION" > "$CHROMIUM_DIR/VERSION"

echo "==> Restructuring framework into deep bundle..."

FRAMEWORK="$CHROMIUM_DIR/Release/Chromium Embedded Framework.framework"

if [ ! -d "$FRAMEWORK" ]; then
    echo "ERROR: Framework not found at $FRAMEWORK"
    exit 1
fi

# The CEF minimal distribution ships the framework as a flat layout.
# Xcode expects a proper macOS deep bundle with Versions/A/ and symlinks.
# Restructure it:
#
# Before (flat):
#   Chromium Embedded Framework.framework/
#     Chromium Embedded Framework  (binary)
#     Libraries/
#     Resources/
#
# After (deep bundle):
#   Chromium Embedded Framework.framework/
#     Versions/
#       A/
#         Chromium Embedded Framework  (binary)
#         Libraries/
#         Resources/
#       Current -> A
#     Chromium Embedded Framework -> Versions/Current/Chromium Embedded Framework
#     Libraries -> Versions/Current/Libraries
#     Resources -> Versions/Current/Resources

# Only restructure if not already a deep bundle
if [ ! -d "$FRAMEWORK/Versions" ]; then
    mkdir -p "$FRAMEWORK/Versions/A"

    # Move contents into Versions/A/
    for item in "$FRAMEWORK"/*; do
        basename="$(basename "$item")"
        if [ "$basename" != "Versions" ]; then
            mv "$item" "$FRAMEWORK/Versions/A/"
        fi
    done

    # Create Current symlink
    ln -sf A "$FRAMEWORK/Versions/Current"

    # Create top-level symlinks
    ln -sf Versions/Current/"Chromium Embedded Framework" "$FRAMEWORK/Chromium Embedded Framework"
    ln -sf Versions/Current/Libraries "$FRAMEWORK/Libraries"
    ln -sf Versions/Current/Resources "$FRAMEWORK/Resources"
fi

echo "==> Fixing framework install name to use @rpath..."
# The CEF binary ships with an install name of
#   @executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework
# This works for a single-binary app but breaks for helper processes whose
# @executable_path is different. Change it to @rpath so that both the main
# app and helper resolve it through their LD_RUNPATH_SEARCH_PATHS.
BINARY="$FRAMEWORK/Versions/A/Chromium Embedded Framework"
CURRENT_INSTALL_NAME=$(otool -D "$BINARY" | tail -1)
if [ "$CURRENT_INSTALL_NAME" != "@rpath/Chromium Embedded Framework.framework/Chromium Embedded Framework" ]; then
    install_name_tool -id "@rpath/Chromium Embedded Framework.framework/Chromium Embedded Framework" "$BINARY"
    echo "    Changed install name from:"
    echo "      $CURRENT_INSTALL_NAME"
    echo "    to:"
    echo "      @rpath/Chromium Embedded Framework.framework/Chromium Embedded Framework"
else
    echo "    Install name already uses @rpath"
fi

echo "==> Cleaning up extraction directory..."
rm -rf "$EXTRACT_DIR"

echo "==> Done!"
echo "    Framework: $FRAMEWORK"
echo "    Version: $CEF_VERSION"
echo ""
echo "    The cached download is at $TMP_DIR/$CEF_FILENAME"
echo "    Delete it to save ~100MB of disk space."
