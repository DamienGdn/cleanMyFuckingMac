#!/bin/bash
# Builds dist/CleanMyFuckingMac.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

# Version = latest git tag (v1.2.3 -> 1.2.3), overridable: VERSION=1.2.3 scripts/build-app.sh
VERSION="${VERSION:-$(git describe --tags --abbrev=0 | sed 's/^v//')}"
BUILD="$(git rev-list --count HEAD)"

APP="dist/CleanMyFuckingMac.app"
ICONSET=".build/AppIcon.iconset"

swift build -c release --product CleanMyFuckingMac
BINARY=".build/release/CleanMyFuckingMac"

rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/CleanMyFuckingMac"

"$BINARY" --render-icon "$ICONSET"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CleanMyFuckingMac</string>
    <key>CFBundleDisplayName</key><string>CleanMyFuckingMac</string>
    <key>CFBundleIdentifier</key><string>local.cleanmyfuckingmac.app</string>
    <key>CFBundleExecutable</key><string>CleanMyFuckingMac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Synced folders (iCloud, Finder) tag files with attributes that codesign rejects.
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "OK : $APP ($VERSION, build $BUILD)"
