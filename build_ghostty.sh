#!/bin/bash
set -e

# Build script for Watchtower with Ghostty

echo "Building Ghostty..."

# Check if Zig is installed
if ! command -v zig &> /dev/null; then
    echo "Error: Zig is not installed."
    echo "Please install Zig 0.13.0 or later:"
    echo "  brew install zig"
    echo "  or download from https://ziglang.org/download/"
    exit 1
fi

# Check Zig version
ZIG_VERSION=$(zig version)
echo "Using Zig version: $ZIG_VERSION"

# Build Ghostty
cd ghostty
echo "Building Ghostty library..."
zig build -Doptimize=ReleaseFast -Demit-docs=false

cd ..

echo ""
echo "Ghostty built successfully!"
echo ""
echo "Next steps:"
echo "1. Open Watchtower.xcodeproj in Xcode"
echo "2. Build and run the Watchtower app"
echo ""
echo "The Ghostty library is located at:"
echo "  ghostty/zig-out/lib/libghostty.a"
