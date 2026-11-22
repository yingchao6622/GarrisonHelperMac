#!/bin/bash
# Builds 卫戍协议小助手.app (Apple Silicon + Intel universal when possible) into ./dist.
# Needs only the Xcode Command Line Tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="卫戍协议小助手"
BUNDLE_ID="local.garrison-helper.mac"
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
# Build number = commits so far; the commit (with -dirty for uncommitted changes) goes into Info.plist, the 关于 section
# and every debug recording, so a report says exactly which build produced it.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi
# Signing: a stable identity keeps the screen-recording permission across rebuilds (ad-hoc signatures change every
# build, so macOS asks again). Set SIGN_IDENTITY, or create a code-signing certificate named
# 「卫戍协议小助手 本地签名」 in Keychain Access (see docs/开发.md); otherwise ad-hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "卫戍协议小助手 本地签名"; then
  SIGN_IDENTITY="卫戍协议小助手 本地签名"
fi
DIST="dist"
APP="$DIST/$APP_NAME.app"
# Never replace the bundle under a running copy: its signature then no longer matches the files on disk and macOS
# refuses its screen captures (「用户拒绝了应用程序、窗口、显示器捕捉的 TCC」) until it is restarted.
if pgrep -f "$PWD/$APP/Contents/MacOS/GarrisonHelper" >/dev/null && [ -z "${FORCE:-}" ]; then
  echo "小助手正在运行：先退出它再打包（FORCE=1 强制替换，运行中的那份会截不了图）。" >&2
  exit 1
fi

if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
  BIN=".build/apple/Products/Release/GarrisonHelper"
else
  swift build -c release
  BIN=".build/release/GarrisonHelper"
fi
WORKER="$(dirname "$BIN")/OCRWorker"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GarrisonHelper"
cp "$WORKER" "$APP/Contents/MacOS/OCRWorker"
cp -R Resources/data Resources/icons Resources/model Resources/field "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp -R licenses "$APP/Contents/Resources/licenses"
cp NOTICE ASSETS.md "$APP/Contents/Resources/"
find "$APP" -name ".DS_Store" -delete   # Finder metadata from the source folders

# App icon: Resources/AppIcon.png, drawn by scripts/make-app-icon.swift (our own art, no game artwork).
[ -f Resources/AppIcon.png ] || swift scripts/make-app-icon.swift Resources/AppIcon.png
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>GarrisonHelper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>GHGitCommit</key><string>$COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>读取游戏窗口画面，用于识别本局信息、场上干员和资金。</string>
</dict>
</plist>
PLIST

if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
  SIGNED="签名：$SIGN_IDENTITY（屏幕录制权限重建后保留）"
else
  codesign --force --deep --sign - "$APP"
  SIGNED="临时签名（重建后要重新勾选屏幕录制权限）"
fi
echo "Built $APP  v$VERSION ($BUILD, $COMMIT)  $SIGNED"
