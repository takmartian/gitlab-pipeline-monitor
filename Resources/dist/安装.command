#!/usr/bin/env bash
# 双击我即可安装：拷到 /Applications、去掉隔离属性（「已损坏」提示的根源）、启动
set -euo pipefail
NAME="GitLab Pipeline Monitor"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SRC_DIR/$NAME.app"

[ -d "$APP" ] || { echo "找不到 $NAME.app，请先双击挂载 dmg 再运行本脚本。"; read -r _; exit 1; }

DEST="/Applications/$NAME.app"
if ! cp -R "$APP" /Applications/ 2>/dev/null; then
  # 没有管理员权限时退回用户目录
  mkdir -p "$HOME/Applications"
  DEST="$HOME/Applications/$NAME.app"
  cp -R "$APP" "$HOME/Applications/"
fi
[ -d "$DEST" ] || true

# 关键一步：去掉隔离属性，否则 Gatekeeper 会说「已损坏，无法打开」
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
xattr -dr com.apple.provenance "$DEST" 2>/dev/null || true

open "$DEST"
echo "已安装并启动：$DEST"
echo "（令牌加密存在 ~/Library/Application Support/$NAME/，与钥匙串无关，不会再弹密码框）"
