#!/bin/zsh
# 用法：./build.sh          只编译到 build/
#       ./build.sh install  编译并安装到 ~/Applications，然后启动
set -euo pipefail
cd "$(dirname "$0")"

NAME=MacTools
APP=build/$NAME.app
INSTALLED=~/Applications/$NAME.app
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)

rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos14 Sources/*.swift -o "$APP/Contents/MacOS/$NAME"
cp Info.plist "$APP/Contents/"
# 用固定的自签名证书签名，辅助功能授权才能跨版本保留；创建方法见 README。
IDENTITY="MacTools Dev"
if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "未找到签名证书“$IDENTITY”，改用临时签名：每次安装后都要重新授权辅助功能"
  IDENTITY=-
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "已编译：$APP"

if [[ "${1:-}" == "install" ]]; then
  # 用正常退出而不是强杀，让旧版本有机会恢复系统睡眠设置
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  # 等到系统里的运行登记也清掉：只等进程退出的话，紧接着启动新版偶尔会报 -600。
  while [[ -n "$(lsappinfo find bundleid="$BUNDLE_ID")" ]]; do sleep 0.2; done
  mkdir -p ~/Applications
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  open "$INSTALLED"
  echo "已安装并启动：$INSTALLED"
fi
