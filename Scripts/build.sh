#!/bin/bash
# ============================================================
#  CallRecorder 构建脚本
#  用于编译并打包为 .tipa 文件（巨魔/TrollStore 安装用）
# ============================================================

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="CallRecorder"
APP_NAME="TRApp"
SCHEME="CallRecorder"
CONFIGURATION="Release"
BUILD_DIR="${PROJECT_DIR}/build"
OUTPUT_DIR="${PROJECT_DIR}/output"
DERIVED_DATA="${BUILD_DIR}/DerivedData"

echo "============================================"
echo "  CallRecorder 构建脚本"
echo "  目标: ${APP_NAME}.app -> ${APP_NAME}.tipa"
echo "============================================"

# Step 1: 清理
echo "[1/5] 清理构建目录..."
rm -rf "${BUILD_DIR}" "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# Step 2: 编译
echo "[2/5] 编译项目..."
xcodebuild \
    -project "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination 'generic/platform=iOS' \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

# Step 3: 查找编译产物
echo "[3/5] 查找 .app 文件..."
APP_PATH=$(find "${DERIVED_DATA}" -name "${APP_NAME}.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
    echo "错误: 找不到 ${APP_NAME}.app"
    exit 1
fi
echo "找到: ${APP_PATH}"

# Step 4: 打包为 .tipa
echo "[4/5] 打包为 .tipa..."
TIPA_DIR="${OUTPUT_DIR}/tipa"
mkdir -p "${TIPA_DIR}/Payload"
cp -R "${APP_PATH}" "${TIPA_DIR}/Payload/"

cd "${TIPA_DIR}"
zip -r "${OUTPUT_DIR}/${APP_NAME}.tipa" Payload/
cd "${PROJECT_DIR}"

# 清理临时目录
rm -rf "${TIPA_DIR}"

# Step 5: 完成
echo "[5/5] 构建完成!"
echo ""
echo "============================================"
echo "  .tipa 文件: ${OUTPUT_DIR}/${APP_NAME}.tipa"
echo "  文件大小: $(du -sh "${OUTPUT_DIR}/${APP_NAME}.tipa" | cut -f1)"
echo "============================================"
echo ""
echo "安装方式:"
echo "  1. 将 ${APP_NAME}.tipa 传输到 iPhone"
echo "  2. 在 TrollStore 中点击打开"
echo "  3. 点击 Install 安装"
echo "============================================"