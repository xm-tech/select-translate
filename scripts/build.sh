#!/bin/bash
# 构建 SelectTranslate.app（直接调用 swiftc，绕开 SwiftPM 在受限沙箱下的 manifest 编译问题）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="SelectTranslate"
BUNDLE_ID="com.maxion.selecttranslate"
BUNDLE="$ROOT/dist/$APP_NAME.app"
TMP="$ROOT/.tmp"
CACHE="$TMP/modcache"
SOURCES="$ROOT/Sources/SelectTranslate"
VERSION="${VERSION:-1.1}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"

mkdir -p "$TMP" "$CACHE"

echo "==> 检查 SDK 版本"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
NO_APPLE_FLAGS=()
SOURCE_FILES=("$SOURCES"/*.swift)
if [ "${SDK_MAJOR}" -lt 26 ]; then
  echo "    当前 SDK 为 ${SDK_VERSION}（< 26），跳过 Apple 本地翻译模块"
  NO_APPLE_FLAGS=(-DNO_APPLE_TRANSLATION)
  SOURCE_FILES=()
  for f in "$SOURCES"/*.swift; do
    case "$(basename "$f")" in
      AppleTranslator.swift|AppleLanguagePackWindow.swift) ;;
      *) SOURCE_FILES+=("$f") ;;
    esac
  done
else
  echo "    当前 SDK 为 ${SDK_VERSION}，启用 Apple 本地翻译"
fi

echo "==> 编译 Swift 源码"
swiftc -O -swift-version 5 \
  -target "$TARGET_ARCH-apple-macos13.0" \
  -module-cache-path "$CACHE" \
  "${NO_APPLE_FLAGS[@]}" \
  "${SOURCE_FILES[@]}" \
  -o "$TMP/$APP_NAME"

echo "==> 生成图标"
if [ ! -f "$ROOT/app/AppIcon.icns" ]; then
  "$TMP/$APP_NAME" --icon "$TMP/icon-1024.png" >/dev/null
  ICONSET="$TMP/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$TMP/icon-1024.png" --out "$ICONSET/icon_$2.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ROOT/app/AppIcon.icns"
fi

echo "==> 组装 $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$TMP/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/app/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT/app/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1 || true

echo "==> 签名（ad-hoc）"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$BUNDLE" 2>&1 | sed 's/^/    /'

echo "==> 完成：$BUNDLE"
codesign -dv "$BUNDLE" 2>&1 | sed 's/^/    /' || true
