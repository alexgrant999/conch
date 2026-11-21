#!/bin/zsh
# Builds build/Conch.app. Pass --install to copy it into /Applications (or ~/Applications) and open it.
set -euo pipefail

cd "${0:A:h}/.."
ROOT=$PWD
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Conch.app"
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/Conch/Contract/Types.swift)
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)

echo "Building Conch $VERSION ($BUILD_NUMBER), release"
swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)

mkdir -p "$BUILD_DIR"
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Conch" "$APP/Contents/MacOS/Conch"

ICNS="$BUILD_DIR/AppIcon.icns"
if [[ ! -f "$ICNS" || scripts/make-icon.swift -nt "$ICNS" ]]; then
  echo "Rendering icon"
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "${ICONSET:?}"
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift "$BUILD_DIR/icon-1024.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD_DIR/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$BUILD_DIR/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Conch</string>
  <key>CFBundleDisplayName</key><string>Conch</string>
  <key>CFBundleIdentifier</key><string>com.alexgrant.conch</string>
  <key>CFBundleExecutable</key><string>Conch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSDesktopFolderUsageDescription</key><string>Commands you run in Conch can read files on your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Commands you run in Conch can read files in Documents.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Commands you run in Conch can read files in Downloads.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Commands you run in Conch can read removable drives.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Commands you run in Conch can read network drives.</string>
  <key>NSAppleEventsUsageDescription</key><string>Commands you run in Conch can control other apps.</string>
  <key>NSMicrophoneUsageDescription</key><string>Commands you run in Conch, such as Claude Code voice dictation, can use the microphone.</string>
  <key>NSCameraUsageDescription</key><string>Commands you run in Conch can use the camera.</string>
</dict>
</plist>
EOF

# A real signing identity keeps macOS privacy grants (Documents, Desktop) across rebuilds. Ad-hoc is the fallback.
# CONCH_SIGN_IDENTITY (set by scripts/release.sh to a Developer ID) signs for distribution instead: hardened runtime,
# secure timestamp and entitlements, which notarization requires.
if [[ -n "${CONCH_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --entitlements scripts/Conch.entitlements --sign "$CONCH_SIGN_IDENTITY" "$APP"
  echo "Signed for distribution with $CONCH_SIGN_IDENTITY"
else
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)
  if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "Signed with $IDENTITY"
  else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc"
  fi
fi

SIZE=$(du -sh "$APP" | cut -f1)
echo "Built $APP ($SIZE)"

if [[ "${1:-}" == "--install" ]]; then
  if [[ -w /Applications ]]; then DEST_DIR=/Applications; else DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; fi
  DEST="$DEST_DIR/Conch.app"
  if pgrep -xq Conch; then
    echo "Conch is running. Quit it (Cmd+Q) and run this again to install." >&2
    exit 1
  fi
  rm -rf "${DEST:?}"
  ditto "$APP" "$DEST"
  echo "Installed $DEST"
  open "$DEST"
fi
