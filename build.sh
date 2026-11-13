#!/usr/bin/env bash
# 构建原生菜单栏 App：swift build → 组装 .app → 生成图标 → 签名（Developer ID 或 ad-hoc）
# 用法：
#   ./build.sh                    # release 构建（本机自用）
#   ./build.sh debug              # debug 构建
#   ./build.sh release --dist     # 额外产出 dmg / zip（dmg 内含双击安装脚本与说明）
#   ./build.sh release --notarize # Developer ID 签名 + Apple 公证 + staple（需证书与 notarytool profile）
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")"

CONFIG="release"
DIST=0
NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --dist) DIST=1 ;;
    --notarize) NOTARIZE=1; DIST=1 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

NAME="GitLab Pipeline Monitor"
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist 2>/dev/null || echo 1.0.0)"
APP="build/$NAME.app"

echo "▸ swift build ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/GitLabPipelineMonitor"

echo "▸ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GitLabPipelineMonitor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf "APPL????" > "$APP/Contents/PkgInfo"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ 生成 App 图标"
  rm -rf Resources/icon.iconset
  swift Tools/make_icon.swift Resources/icon.iconset
  iconutil -c icns Resources/icon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 签名：有 Developer ID 就用它 + hardened runtime；否则退回 ad-hoc
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)"
IDENTITY="${CODESIGN_IDENTITY:-$IDENTITY}"
if [ -n "$IDENTITY" ]; then
  echo "▸ 签名：$IDENTITY（hardened runtime + 时间戳）"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "▸ ad-hoc 签名（分发时接收方需去掉隔离属性，dmg 内已附安装脚本与说明）"
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

if [ "$NOTARIZE" = 1 ]; then
  PROFILE="${NOTARY_PROFILE:-glpm}"
  echo "▸ 公证提交（notarytool keychain profile: $PROFILE）"
  ditto -c -k --keepParent "$APP" build/notarize.zip
  xcrun notarytool submit build/notarize.zip --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f build/notarize.zip
fi

if [ "$DIST" = 1 ]; then
  echo "▸ 打包 dmg / zip"
  STAGE="build/dmgstage"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp "Resources/dist/安装.command" "$STAGE/安装.command"
  cp "Resources/dist/安装说明.txt" "$STAGE/安装说明.txt"
  chmod +x "$STAGE/安装.command"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "build/$NAME-$VERSION.dmg" >/dev/null
  # zip 里也放安装脚本与说明（不带 Applications 快捷方式）
  ZSTAGE="build/zipstage/$NAME"
  rm -rf build/zipstage
  mkdir -p "$ZSTAGE"
  cp -R "$APP" "$ZSTAGE/"
  cp "Resources/dist/安装.command" "$ZSTAGE/安装.command"
  cp "Resources/dist/安装说明.txt" "$ZSTAGE/安装说明.txt"
  chmod +x "$ZSTAGE/安装.command"
  ditto -c -k --keepParent "$ZSTAGE" "build/$NAME-$VERSION.zip"
  echo "📦 build/$NAME-$VERSION.dmg"
  echo "📦 build/$NAME-$VERSION.zip"
fi

echo "✅ $APP"
