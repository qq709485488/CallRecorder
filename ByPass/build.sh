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

# 2. 解压原始 .tipa (使用 Python zipfile 支持新版 zip 格式)
echo "[2/5] Extracting original .tipa..."
mkdir -p extracted
python3 -c "
import zipfile
with zipfile.ZipFile('TRApp_2.14-542.tipa', 'r') as zf:
    zf.extractall('extracted')
print('Extraction complete')
"

# 3. 复制 dylib 到 app 目录
echo "[3/5] Copying dylib to app bundle..."
cp TrollRecorderBypass.dylib "extracted/Payload/TRApp.app/"

# 4. 注入 dylib 到二进制 (使用 Python 脚本修改 Mach-O)
echo "[4/5] Injecting dylib into binaries..."

cd "extracted/Payload/TRApp.app"

# 注入到 TRApp
echo "Injecting into TRApp..."
python3 "$GITHUB_WORKSPACE/ByPass/inject_dylib.py" TRApp "@executable_path/TrollRecorderBypass.dylib"

# 注入到 TRCallMonitor
if [ -f "TRCallMonitor" ]; then
    echo "Injecting into TRCallMonitor..."
    python3 "$GITHUB_WORKSPACE/ByPass/inject_dylib.py" TRCallMonitor "@executable_path/TrollRecorderBypass.dylib"
fi

cd -

# 5. 重新打包为 .tipa
echo "[5/5] Repackaging as .tipa..."
cd extracted
ditto -c -k --sequesterRsrc --keepParent Payload ../TRApp_ByPass.tipa
cd ..

echo "=== Done! ==="
ls -la TRApp_ByPass.tipa