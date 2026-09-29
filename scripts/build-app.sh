#!/bin/zsh
# Builds Paint.app — a fully local, native Swift replica of Windows 11 Paint.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/Paint.app"
BUILD_CONFIG="${1:-release}"

echo "==> swift build -c $BUILD_CONFIG"
swift build -c "$BUILD_CONFIG"
BIN="$ROOT/.build/$BUILD_CONFIG/Paint"

echo "==> rendering app icon"
ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/.build/AppIcon.icns"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Paint"
cp "$ROOT/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Paint</string>
    <key>CFBundleIdentifier</key>
    <string>local.paint.replica</string>
    <key>CFBundleName</key>
    <string>Paint</string>
    <key>CFBundleDisplayName</key>
    <string>Paint</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
                <string>public.png</string>
                <string>public.jpeg</string>
                <string>com.compuserve.gif</string>
                <string>public.tiff</string>
                <string>public.bmp</string>
                <string>public.heic</string>
                <string>org.webmproject.webp</string>
            </array>
        </dict>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" 2>/dev/null || true
echo "==> done: $APP"
echo "    open Paint.app   (or: open \"$APP\")"
