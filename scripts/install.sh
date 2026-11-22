#!/bin/bash
# 构建并安装到 ~/Applications，然后启动（菜单栏 App，无 Dock 图标）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SelectTranslate"
SOURCE="$ROOT/dist/$APP_NAME.app"
TARGET_DIR="$HOME/Applications"
TARGET="$TARGET_DIR/$APP_NAME.app"

"$ROOT/scripts/build.sh"

mkdir -p "$TARGET_DIR"
echo "==> 安装到 $TARGET"
# 先退出旧实例（如果正在运行）
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
rm -rf "$TARGET"
cp -R "$SOURCE" "$TARGET"

echo "==> 启动"
open "$TARGET"
echo "==> 已安装并启动：$TARGET"
echo "    首次运行需要在「系统设置 › 隐私与安全性 › 辅助功能」里勾选「划词翻译」。"
