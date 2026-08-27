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

# 颜色（em 面板已支持 ANSI 渲染，始终输出）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LAUNCH=false
if [ "$1" = "--launch" ]; then
  LAUNCH=true
fi

# 定位项目根目录（脚本所在目录）
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

echo ""
echo "========================================"
echo -e "  ${GREEN}EasyNote 一键构建安装${NC}"
echo "========================================"
echo ""

# ---------- 平台判断 ----------
UNAME=$(uname -s)
case "$UNAME" in
  Darwin)  PLATFORM="macos" ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
  *)       echo -e "${RED}不支持的平台: $UNAME（仅支持 macOS / Windows）${NC}"; exit 1 ;;
esac

# ---------- 构建 ----------
echo -e "${GREEN}[1/3] 构建 Release 版: $PLATFORM${NC}"
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
  echo -e "${RED}构建产物不存在: $APP_SOURCE${NC}"
  exit 1
fi

# ---------- 安装 ----------
echo -e "${GREEN}[2/3] 安装到系统...${NC}"
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
  echo -e "  已安装到 ${GREEN}$APP_DEST${NC}"
else
  # Windows：整目录复制（含 exe + 依赖 dll + data）
  if [ -d "$APP_DEST" ]; then
    rm -rf "$APP_DEST"
  fi
  mkdir -p "$APP_DEST"
  cp -r "$APP_SOURCE"/. "$APP_DEST"/
  echo -e "  已安装到 ${GREEN}$APP_DEST${NC}"
fi

# ---------- 启动（可选） ----------
echo -e "${GREEN}[3/3] 完成${NC}"
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
echo -e "${GREEN}构建安装完成${NC}"
echo "========================================"
