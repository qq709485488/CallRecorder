#!/bin/bash
# TrollRecorder 验证绕过打包脚本
# 在 GitHub Actions macOS 环境中运行

set -e

echo "=== TrollRecorder Bypass Packager ==="

# 1. 编译绕过 dylib
echo "[1/5] Compiling bypass dylib..."
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)

# 编译为 .o
clang -c \
    -arch arm64 \
    -target arm64-apple-ios15.0 \
    -isysroot "$SDK_PATH" \
    -miphoneos-version-min=15.0 \
    -fobjc-arc \
    -o TrollRecorderBypass.o \
    TrollRecorderBypass.m

# 链接为 dylib，使用 -target 确保与 iOS 兼容
# -Wl,-no_fixup_chains 禁用链式修复，使用传统 DYLD_INFO 格式以兼容旧版 ldid
clang -dynamiclib \
    -arch arm64 \
    -target arm64-apple-ios15.0 \
    -isysroot "$SDK_PATH" \
    -miphoneos-version-min=15.0 \
    -framework Foundation \
    -framework Security \
    -Wl,-dead_strip \
    -Wl,-segalign,4000 \
    -Wl,-no_fixup_chains \
    -o TrollRecorderBypass.dylib \
    TrollRecorderBypass.o

# 设置 install name
install_name_tool -id "@executable_path/TrollRecorderBypass.dylib" TrollRecorderBypass.dylib

# 去掉调试符号
strip -x TrollRecorderBypass.dylib 2>/dev/null || true

# 安装 ldid 并用它签名
if ! command -v ldid &> /dev/null; then
    echo "Installing ldid..."
    brew install ldid 2>/dev/null || {
        curl -sL https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_macosx_x86_64 -o /usr/local/bin/ldid
        chmod +x /usr/local/bin/ldid
    }
fi
echo "Signing dylib with ldid..."
ldid -S TrollRecorderBypass.dylib

# 验证 dylib 结构
echo "=== Dylib verification ==="
echo "File type:"
file TrollRecorderBypass.dylib
echo "Architecture:"
lipo -info TrollRecorderBypass.dylib 2>/dev/null || echo "Not a fat binary"
echo "Load commands:"
otool -l TrollRecorderBypass.dylib 2>/dev/null | grep -E "(LC_CODE|LC_VERSION|LC_BUILD|LC_LOAD|LC_ID_DYLIB|cmd )" | head -20
echo "Dependencies:"
otool -L TrollRecorderBypass.dylib 2>/dev/null || true
echo "Size:"
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