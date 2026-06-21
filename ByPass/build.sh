#!/bin/bash
# TrollRecorder 验证绕过打包脚本
# 在 GitHub Actions macOS 环境中运行

set -e

echo "=== TrollRecorder Bypass Packager ==="

# 1. 编译绕过 dylib
echo "[1/5] Compiling bypass dylib..."
clang -dynamiclib \
    -arch arm64 \
    -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
    -miphoneos-version-min=16.0 \
    -framework Foundation \
    -framework Security \
    -framework UIKit \
    -fobjc-arc \
    -o TrollRecorderBypass.dylib \
    TrollRecorderBypass.m

echo "Dylib compiled successfully"
ls -la TrollRecorderBypass.dylib

# 2. 解压原始 .tipa
echo "[2/5] Extracting original .tipa..."
unzip -o TRApp_2.14-542.tipa -d extracted

# 3. 安装 insert_dylib 工具
echo "[3/5] Installing insert_dylib..."
if ! command -v insert_dylib &> /dev/null; then
    # 下载预编译的 insert_dylib 或从源码编译
    git clone https://github.com/Tyilo/insert_dylib.git /tmp/insert_dylib
    cd /tmp/insert_dylib
    xcodebuild -project insert_dylib.xcodeproj -scheme insert_dylib -configuration Release -derivedDataPath build
    cp build/Build/Products/Release/insert_dylib /usr/local/bin/
    cd -
fi

# 复制 dylib 到 app 目录
cp TrollRecorderBypass.dylib "extracted/Payload/TRApp.app/"

# 4. 注入 dylib 到主二进制
echo "[4/5] Injecting dylib into binaries..."

# 注入到 TRApp
insert_dylib "@executable_path/TrollRecorderBypass.dylib" "extracted/Payload/TRApp.app/TRApp" --strip-codesig --all-yes
# 重新签名（对于 TrollStore 不是必须的，但保持完整性）
codesign -f -s - "extracted/Payload/TRApp.app/TRApp" 2>/dev/null || echo "Codesign skipped for TrollStore"

# 也注入到 TRCallMonitor 守护进程
cp TrollRecorderBypass.dylib "extracted/Payload/TRApp.app/TrollRecorderBypass.dylib"
if [ -f "extracted/Payload/TRApp.app/TRCallMonitor" ]; then
    insert_dylib "@executable_path/TrollRecorderBypass.dylib" "extracted/Payload/TRApp.app/TRCallMonitor" --strip-codesig --all-yes
    codesign -f -s - "extracted/Payload/TRApp.app/TRCallMonitor" 2>/dev/null || echo "Codesign skipped for TRCallMonitor"
fi

# 5. 重新打包为 .tipa
echo "[5/5] Repackaging as .tipa..."
cd extracted
zip -r ../TRApp_ByPass.tipa Payload
cd ..

echo "=== Done! ==="
ls -la TRApp_ByPass.tipa