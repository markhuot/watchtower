# Watchtower

<video src="resources/screencast.mp4" controls></video>

A macOS terminal app for AI-assisted development workflows. Multiple 80-column terminals in a horizontally scrolling layout, powered by [Ghostty](https://github.com/ghostty-org/ghostty).

## Building

**Prerequisites**: macOS 13+, Xcode 15+, Zig 0.15+

```bash
# Clone with submodules
git clone --recursive <repo-url>
cd watchtower

# Build Ghostty (one-time, takes a few minutes)
cd ghostty
zig build -Doptimize=ReleaseFast -Demit-docs=false -Demit-xcframework=true
cd ..

# Build the app
xcodebuild -project Watchtower.xcodeproj -scheme Watchtower -configuration Debug build
```

Or open `Watchtower.xcodeproj` in Xcode and press Cmd+R.

## Status

The app builds and links against libghostty. Ghostty surface creation, keyboard/mouse input, and terminal rendering are implemented but not yet tested at runtime. PTY spawning may require sandbox entitlement changes.

## License

MIT
