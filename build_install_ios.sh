#!/bin/bash

# =============================================================================
# build_install_ios.sh - 构建并安装 iOS Release 版到已连接的真机
# =============================================================================
# 用法：
#   ./build_install_ios.sh              # 构建 + 安装 + 启动（默认）
#   ./build_install_ios.sh --no-launch  # 只构建 + 安装，不启动
#
# 依赖：
#   - 已连接 iPhone/iPad（USB 或同一 Wi-Fi）
#   - 已配置 iOS 签名（Xcode 自动签名 / 开发者证书）
#   - xcrun devicectl（Xcode 15+ 自带）
# =============================================================================

set -e

# 颜色（em 面板已支持 ANSI 渲染，始终输出）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LAUNCH=true
if [ "$1" = "--no-launch" ]; then
  LAUNCH=false
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

echo ""
echo "========================================"
echo "  EasyNote iOS Release 构建安装"
echo "========================================"
echo ""

# ---------- 1. 查找已连接的真机 ----------
echo -e "${GREEN}[1/4] 查找已连接的 iOS 设备...${NC}"
# 优先取第一个已连接的 iPhone/iPad（排除模拟器）
DEVICE_ID=$(flutter devices 2>/dev/null | grep -iE "iphone|ipad" | grep -v "simulator" | head -1 | grep -oE "[0-9a-fA-F-]{20,}" | head -1)
if [ -z "$DEVICE_ID" ]; then
  echo -e "${RED}未找到已连接的 iOS 真机。请通过 USB 连接并解锁设备（允许「信任此电脑」）。${NC}"
  exit 1
fi
echo -e "  设备 ID: ${GREEN}$DEVICE_ID${NC}"

# ---------- 2. 构建 Release ----------
echo -e "${GREEN}[2/4] 构建 iOS Release 版（约 1-2 分钟）...${NC}"
flutter build ios --release
APP_SOURCE="$PROJECT_DIR/build/ios/iphoneos/Runner.app"
if [ ! -d "$APP_SOURCE" ]; then
  echo -e "${RED}构建产物不存在: $APP_SOURCE${NC}"
  exit 1
fi
echo -e "  ${GREEN}构建完成: Runner.app${NC}"

# ---------- 3. 安装到设备 ----------
echo -e "${GREEN}[3/4] 安装到设备...${NC}"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_SOURCE"
echo -e "  安装完成"

# ---------- 4. 启动（可选） ----------
echo -e "${GREEN}[4/4] 完成${NC}"
BUNDLE_ID=$(defaults read "$APP_SOURCE/Info" CFBundleIdentifier 2>/dev/null || echo "com.example.lanNotes")
if [ "$LAUNCH" = true ]; then
  echo "  启动应用（Bundle: $BUNDLE_ID）..."
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
else
  echo "  如需启动请加参数：./build_install_ios.sh（默认启动）"
fi

echo ""
echo "========================================"
echo -e "${GREEN}iOS Release 构建安装完成${NC}"
echo "========================================"
