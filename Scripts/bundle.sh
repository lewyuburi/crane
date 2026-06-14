#!/bin/bash
# Builds Crane as a proper macOS .app bundle (release, with a Dock icon) and
# optionally launches it. Run from the repo root: ./Scripts/bundle.sh [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Crane.app"
CONTENTS="$APP/Contents"

echo "▸ Building release…"
swift build -c release

echo "▸ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Helpers"
cp ".build/release/CraneApp" "$CONTENTS/MacOS/Crane"

echo "▸ Bundling the crane CLI…"
cp ".build/release/crane" "$CONTENTS/Helpers/crane"

echo "▸ Bundling app templates…"
cp -R "templates" "$CONTENTS/Resources/templates"

echo "▸ Generating icon…"
ICONSET="build/Crane.iconset"
rm -rf "$ICONSET"
swift Scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

# Single source of truth: the marketing version comes from CraneVersion.swift (which release.yml
# stamps from the git tag), so the Info.plist and `crane --version` never drift apart.
VERSION="$(grep -oE 'current = "[0-9][0-9.]*"' Sources/CraneKit/CraneVersion.swift | grep -oE '[0-9][0-9.]*')"
echo "▸ Version $VERSION"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Crane</string>
    <key>CFBundleDisplayName</key><string>Crane</string>
    <key>CFBundleIdentifier</key><string>dev.crane.Crane</string>
    <key>CFBundleExecutable</key><string>Crane</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc signing…"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"

echo "✓ Built $APP"
if [[ "${1:-}" == "--run" ]]; then
    open "$APP"
fi
