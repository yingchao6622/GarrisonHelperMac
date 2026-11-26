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
# Signing: a stable identity keeps the screen-recording permission across rebuilds and updates (macOS remembers it by
# the signature; ad-hoc signatures change every build, so it asks again). In order:
#   1. SIGN_P12 (+ SIGN_P12_PASSWORD): the release certificate as a .p12 file. Releases use it (GitHub secrets), and a
#      local build uses ~/Library/Application Support/卫戍协议小助手-签名/signing.p12 when it is there. It is imported
#      into a throwaway keychain file that is deleted afterwards; the login keychain and its search list are untouched.
#   2. SIGN_IDENTITY, or a code-signing certificate named 「卫戍协议小助手 本地签名」 in Keychain Access.
#   3. Otherwise ad-hoc.
LOCAL_SIGN_DIR="$HOME/Library/Application Support/卫戍协议小助手-签名"
if [ -z "${SIGN_P12:-}" ] && [ -f "$LOCAL_SIGN_DIR/signing.p12" ] && [ -f "$LOCAL_SIGN_DIR/p12-password.txt" ]; then
  SIGN_P12="$LOCAL_SIGN_DIR/signing.p12"
  SIGN_P12_PASSWORD="$(cat "$LOCAL_SIGN_DIR/p12-password.txt")"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SIGN_KEYCHAIN=""
if [ -z "$SIGN_IDENTITY" ] && [ -z "${SIGN_P12:-}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "卫戍协议小助手 本地签名"; then
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

if [ -n "${SIGN_P12:-}" ]; then
  KC_DIR="$(mktemp -d)"
  SIGN_KEYCHAIN="$KC_DIR/sign.keychain-db"
  KC_PASS="$(openssl rand -hex 16)"
  trap 'security delete-keychain "$SIGN_KEYCHAIN" 2>/dev/null || true; rm -rf "$KC_DIR"' EXIT
  echo "签名：导入证书到临时钥匙串"
  security create-keychain -p "$KC_PASS" "$SIGN_KEYCHAIN"
  security set-keychain-settings -lut 3600 "$SIGN_KEYCHAIN"
  security unlock-keychain -p "$KC_PASS" "$SIGN_KEYCHAIN"
  # On CI the throwaway keychain also goes on the user search list (codesign and the key partition list look the
  # private key up there on the runner); a local build leaves the search list alone.
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    # shellcheck disable=SC2046
    security list-keychains -d user -s "$SIGN_KEYCHAIN" $(security list-keychains -d user | tr -d '"')
  fi
  security import "$SIGN_P12" -k "$SIGN_KEYCHAIN" -f pkcs12 -P "${SIGN_P12_PASSWORD:-}" -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$SIGN_KEYCHAIN" >/dev/null
  security find-identity -p codesigning "$SIGN_KEYCHAIN"
  CERT_SHA1="$(security find-identity -p codesigning "$SIGN_KEYCHAIN" | awk '/1\)/{print $2; exit}')"
  [ -n "$CERT_SHA1" ] || { echo "签名证书导入失败" >&2; exit 1; }
  codesign --force --deep --keychain "$SIGN_KEYCHAIN" --sign "$CERT_SHA1" "$APP"
  SIGNED="签名：发布证书 ${CERT_SHA1:0:8}（屏幕录制权限更新后保留）"
elif [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
  SIGNED="签名：$SIGN_IDENTITY（屏幕录制权限重建后保留）"
else
  codesign --force --deep --sign - "$APP"
  SIGNED="临时签名（重建后要重新勾选屏幕录制权限）"
fi
echo "Built $APP  v$VERSION ($BUILD, $COMMIT)  $SIGNED"
