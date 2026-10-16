#!/bin/zsh
set -eu
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/줍줍.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/DownloadTidy" "$APP_DIR/Contents/MacOS/DownloadTidy"
if [[ -f "$PROJECT_DIR/assets/AppIcon.icns" ]]; then
  cp "$PROJECT_DIR/assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>줍줍</string>
<key>CFBundleDisplayName</key><string>줍줍</string>
<key>CFBundleIdentifier</key><string>local.blossom.download-tidy</string>
<key>CFBundleExecutable</key><string>DownloadTidy</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSDownloadsFolderUsageDescription</key><string>다운로드 파일을 분류하고 검색하며, 선택한 파일을 정리하기 위해 접근합니다.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
print -r -- "$APP_DIR"
