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


LAUNCH=true
if [ "$1" = "--no-launch" ]; then
  LAUNCH=false
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

echo ""
echo "========================================"
echo "  EasyNote iOS Release Build & Install"
echo "========================================"
echo ""

# ---------- 1. 查找已连接的真机 ----------
echo -e "[1/4] Finding connected iOS device..."
# 优先取第一个已连接的 iPhone/iPad（排除模拟器）
DEVICE_ID=$(flutter devices 2>/dev/null | grep -iE "iphone|ipad" | grep -v "simulator" | head -1 | grep -oE "[0-9a-fA-F-]{20,}" | head -1)
if [ -z "$DEVICE_ID" ]; then
  echo -e "No connected iOS device found. Connect via USB and unlock (trust this computer)."
  exit 1
fi
echo -e "  Device ID: $DEVICE_ID"

# ---------- 2. 构建 Release ----------
echo -e "[2/4] Building iOS release (~1-2 min)..."
flutter build ios --release
APP_SOURCE="$PROJECT_DIR/build/ios/iphoneos/Runner.app"
if [ ! -d "$APP_SOURCE" ]; then
  echo -e "构建产物不存在: $APP_SOURCE"
  exit 1
fi
echo -e "  Build complete: Runner.app"

# ---------- 3. 安装到设备 ----------
echo -e "[3/4] Installing to device..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_SOURCE"
echo -e "  Install complete"

# ---------- 4. 启动（可选） ----------
echo -e "[4/4] Done"
BUNDLE_ID=$(defaults read "$APP_SOURCE/Info" CFBundleIdentifier 2>/dev/null || echo "com.example.lanNotes")
if [ "$LAUNCH" = true ]; then
  echo "  Launching app (Bundle: $BUNDLE_ID)..."
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
else
  echo "  To launch: ./build_install_ios.sh (default launches)"
fi

echo ""
echo "========================================"
echo -e "iOS Release build & install complete"
echo "========================================"
