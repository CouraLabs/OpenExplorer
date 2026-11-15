#!/bin/bash
# Builds "Open Explorer.app" into ./build using swiftc directly.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Open Explorer.app"
CONTENTS="$APP/Contents"
ARCH="$(uname -m)"

mkdir -p build
echo "Compiling…"
swiftc -swift-version 5 -parse-as-library -O \
    -target "${ARCH}-apple-macos14.4" \
    Sources/OpenExplorer/*.swift \
    -o build/OpenExplorer

ICNS="Resources/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ scripts/make-icon.swift -nt "$ICNS" ] || [ Sources/OpenExplorer/IconRenderer.swift -nt "$ICNS" ]; then
    echo "Rendering app icons…"
    rm -rf build/AppIcon.iconset build/icons
    mkdir -p Resources build/AppIcon.iconset
    swiftc -parse-as-library scripts/make-icon.swift Sources/OpenExplorer/IconRenderer.swift -o build/make-icon
    build/make-icon build/icons >/dev/null
    for size in 16 32 128 256 512; do
        sips -z $size $size build/icons/icon-standard.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double build/icons/icon-standard.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns build/AppIcon.iconset -o "$ICNS"
    rm -f Resources/AppIcon-1024.png
    cp build/icons/icon-*.png Resources/
fi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp build/OpenExplorer "$CONTENTS/MacOS/OpenExplorer"
cp "$ICNS" "$CONTENTS/Resources/AppIcon.icns"

# File-type icons (vscode-icons, MIT). Fetched once by scripts/fetch-vscode-icons.sh.
if [ ! -f Resources/vscode-icons/mapping.json ]; then
    scripts/fetch-vscode-icons.sh
fi
cp -R Resources/vscode-icons "$CONTENTS/Resources/vscode-icons"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Open Explorer</string>
    <key>CFBundleDisplayName</key><string>Open Explorer</string>
    <key>CFBundleIdentifier</key><string>com.couralabs.openexplorer</string>
    <key>CFBundleExecutable</key><string>OpenExplorer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSDesktopFolderUsageDescription</key><string>Open Explorer needs access to show the contents of your Desktop folder.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Open Explorer needs access to show the contents of your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Open Explorer needs access to show the contents of your Downloads folder.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>Open Explorer needs access to show files on removable volumes.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Open Explorer needs access to show files on network volumes.</string>
    <key>NSAppleEventsUsageDescription</key><string>Open Explorer opens folders in Terminal.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built: $APP"
echo "Run:   open \"$APP\""
