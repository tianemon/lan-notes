#!/bin/bash

# =============================================================================
# init.sh - 项目初始化脚本
# =============================================================================
# 每个 session 开始时运行此脚本，确保环境已正确设置且开发服务器正在运行。
# =============================================================================

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_DIR="C:/Users/81197/EasyMintProject/lan-notes"

echo ""
echo "========================================"
echo "  环境初始化 - 局域网笔记"
echo "========================================"
echo ""

# =============================================================================
# 1. 环境检测
# =============================================================================

# Java（Android 构建必需；GUI 环境不加载 shell 配置，这里显式导出）
if [ -z "$JAVA_HOME" ]; then
  for JDK in /opt/homebrew/opt/openjdk@21 /opt/homebrew/opt/openjdk@17 /usr/local/opt/openjdk@21; do
    if [ -x "$JDK/bin/java" ]; then
      export JAVA_HOME="$JDK"
      export PATH="$JAVA_HOME/bin:$PATH"
      break
    fi
  done
fi

if command -v java &> /dev/null; then
    echo -e "  ${GREEN}✓${NC} Java $(java -version 2>&1 | head -1)"
else
    echo -e "  ${YELLOW}⚠${NC} Java 未找到（Android 构建需要）"
fi
echo -e "${YELLOW}检测开发环境...${NC}"

# Flutter 检测
if command -v flutter &> /dev/null; then
    FLUTTER_VER=$(flutter --version 2>/dev/null | grep -m1 "Flutter" || echo "unknown")
    echo -e "  ${GREEN}✓${NC} Flutter: $FLUTTER_VER"
else
    echo -e "  ${RED}✗${NC} Flutter 未安装"
    echo -e "  请先安装 Flutter SDK: https://docs.flutter.dev/get-started/install"
    exit 1
fi

# Git 检测
GIT_AVAILABLE=false
if command -v git &> /dev/null; then
    echo -e "  ${GREEN}✓${NC} Git $(git --version | cut -d' ' -f3)"
    GIT_AVAILABLE=true
else
    echo -e "  ${YELLOW}⚠${NC} Git 未安装"
fi

# CodeGraph 索引
if command -v codegraph &> /dev/null; then
    echo -e "  ${GREEN}✓${NC} CodeGraph $(codegraph --version 2>&1 | head -1)"
    codegraph init -i "$PROJECT_DIR" 2>&1 | while IFS= read -r line; do
        echo -e "  ${GREEN}  ${NC} $line"
    done
else
    echo -e "  ${YELLOW}⚠${NC} CodeGraph 未安装（代码智能索引，可选）"
fi

echo ""

# =============================================================================
# 2. 安装依赖
# =============================================================================

echo -e "${YELLOW}安装 Dart 依赖 (flutter pub get)...${NC}"
if [ -f "$PROJECT_DIR/pubspec.yaml" ]; then
    (cd "$PROJECT_DIR" && flutter pub get)
else
    echo -e "  ${YELLOW}⚠${NC} pubspec.yaml 不存在，跳过（工程尚未创建）"
fi

echo ""

# =============================================================================
# 3. 验证
# =============================================================================

echo -e "${YELLOW}验证工程可编译...${NC}"
if [ -f "$PROJECT_DIR/pubspec.yaml" ] && command -v flutter &> /dev/null; then
    (cd "$PROJECT_DIR" && flutter analyze 2>&1 | tail -3 || true)
fi

echo -e "${GREEN}========================================"
echo "  环境就绪！"
echo "=======================================${NC}"
echo ""
