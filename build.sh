#!/bin/zsh
# 用法：./build.sh          只编译到 build/
#       ./build.sh install  编译并安装到 ~/Applications，然后启动
set -euo pipefail
cd "$(dirname "$0")"

APP=build/LidAwake.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos14 Sources/*.swift -o "$APP/Contents/MacOS/LidAwake"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "已编译：$APP"

if [[ "${1:-}" == "install" ]]; then
  # 用正常退出而不是强杀，让旧版本有机会恢复系统睡眠设置
  osascript -e 'tell application id "local.mxby.lidawake" to quit' 2>/dev/null || true
  while pgrep -qx LidAwake; do sleep 0.2; done
  mkdir -p ~/Applications
  rm -rf ~/Applications/LidAwake.app
  ditto "$APP" ~/Applications/LidAwake.app
  open ~/Applications/LidAwake.app
  echo "已安装并启动：~/Applications/LidAwake.app"
fi
