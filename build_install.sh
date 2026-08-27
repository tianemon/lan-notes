#!/bin/bash

# =============================================================================
# build_install.sh - 一键构建并安装 EasyNote 到系统
# =============================================================================
# 用法：
#   ./build_install.sh            # 构建 Release 并安装（不启动）
#   ./build_install.sh --launch   # 构建 Release 并安装，随后启动应用
#
# 平台：
#   macOS  → flutter build macos --release，安装到 /Applications/EasyNote.app
#   Windows→ flutter build windows --release --no-tree-shake-icons
#            （--no-tree-shake-icons：MaterialIcons 字体子集化在 Windows 下
#             会漏掉运行时间接引用的图标字形，导致文件夹/设备图标空白，
#             见 CLAUDE.md 规则 8），安装到 %LOCALAPPDATA%\EasyNote\EasyNote.exe
# =============================================================================

set -e


LAUNCH=false
if [ "$1" = "--launch" ]; then
  LAUNCH=true
fi

# 定位项目根目录（脚本所在目录）
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

echo ""
echo "========================================"
echo "  EasyNote 一键构建安装"
echo "========================================"
echo ""

# ---------- 平台判断 ----------
UNAME=$(uname -s)
case "$UNAME" in
  Darwin)  PLATFORM="macos" ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
  *)       echo -e "不支持的平台: $UNAME（仅支持 macOS / Windows）"; exit 1 ;;
esac

# ---------- 构建 ----------
echo -e "[1/3] 构建 Release 版: $PLATFORM"
if [ "$PLATFORM" = "macos" ]; then
  flutter build macos --release
  APP_SOURCE="$PROJECT_DIR/build/macos/Build/Products/Release/EasyNote.app"
  APP_DEST="/Applications/EasyNote.app"
else
  flutter build windows --release --no-tree-shake-icons
  APP_SOURCE="$PROJECT_DIR/build/windows/x64/runner/Release"
  APP_DEST="$LOCALAPPDATA/EasyNote"
fi

if [ ! -e "$APP_SOURCE" ]; then
  echo -e "构建产物不存在: $APP_SOURCE"
  exit 1
fi

# ---------- 安装 ----------
echo -e "[2/3] 安装到系统..."
if [ "$PLATFORM" = "macos" ]; then
  # 若应用正在运行，先退出（否则替换会失败）
  if pgrep -f "$APP_DEST/Contents/MacOS/EasyNote" >/dev/null 2>&1; then
    echo "  EasyNote 正在运行，先退出..."
    osascript -e 'quit app "EasyNote"' 2>/dev/null || true
    sleep 2
    pkill -f "$APP_DEST/Contents/MacOS/EasyNote" 2>/dev/null || true
  fi
  rm -rf "$APP_DEST"
  cp -R "$APP_SOURCE" "$APP_DEST"
  # 移除隔离属性（否则首次打开可能被 Gatekeeper 拦截）
  xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true
  echo -e "  已安装到 $APP_DEST"
else
  # Windows：整目录复制（含 exe + 依赖 dll + data）
  if [ -d "$APP_DEST" ]; then
    rm -rf "$APP_DEST"
  fi
  mkdir -p "$APP_DEST"
  cp -r "$APP_SOURCE"/. "$APP_DEST"/
  echo -e "  已安装到 $APP_DEST"
fi

# ---------- 启动（可选） ----------
echo -e "[3/3] 完成"
if [ "$LAUNCH" = true ]; then
  echo "  启动 EasyNote..."
  if [ "$PLATFORM" = "macos" ]; then
    open "$APP_DEST"
  else
    "$APP_DEST/EasyNote.exe" &
  fi
else
  echo "  如需启动请加参数：./build_install.sh --launch"
fi

echo ""
echo "========================================"
echo -e "构建安装完成"
echo "========================================"
