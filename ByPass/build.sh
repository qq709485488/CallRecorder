#!/bin/bash
# TrollRecorder 验证绕过打包脚本 v7
# 方案：dylib 注入 + SecItemCopyMatching Hook + 全类方法替换
# 在 GitHub Actions macOS 环境中运行

set -e

echo "=== TrollRecorder Bypass v7 (Dylib + Keychain Hook) ==="
echo "Strategy: Hook SecItemCopyMatching + NSUserDefaults + patch all verification methods"
echo "Target: Original TRApp_2.14-542"
echo "Date: $(date)"
echo ""

GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"

# 1. 解压原始 .tipa
echo "[1/6] Extracting original .tipa..."
python3 -c "
import zipfile
with zipfile.ZipFile('TRApp_2.14-542.tipa', 'r') as zf:
    zf.extractall('extracted')
print('Extraction complete')
"

# 2. 安装 ldid
echo "[2/6] Installing ldid..."
if ! command -v ldid &> /dev/null; then
    brew install ldid 2>/dev/null || {
        curl -sL https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_macosx_x86_64 -o /usr/local/bin/ldid
        chmod +x /usr/local/bin/ldid
    }
fi
ldid --version 2>/dev/null || echo "ldid installed"

# 3. 编译 dylib
echo "[3/6] Compiling TrollRecorderBypass.dylib..."
clang -arch arm64 -dynamiclib \
    -framework Foundation \
    -framework Security \
    -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
    -miphoneos-version-min=14.0 \
    -o TrollRecorderBypass.dylib \
    "$GITHUB_WORKSPACE/ByPass/TrollRecorderBypass.m"

if [ ! -f TrollRecorderBypass.dylib ]; then
    echo "ERROR: Failed to compile dylib"
    exit 1
fi
echo "Dylib compiled: $(file TrollRecorderBypass.dylib)"

# 4. 注入 dylib 到所有二进制文件
echo "[4/6] Injecting dylib into binaries..."

cd "extracted/Payload/TRApp.app"

# 要处理的二进制文件列表
BINARIES="TRApp TRCallMonitor TRAudioRecorder TRCallRecorder TRSyncLite TRVoiceMemo TRAudioPlayer TRSpeechUtterance"

for binary in $BINARIES; do
    if [ ! -f "$binary" ]; then
        continue
    fi
    
    echo ""
    echo "  Processing: $binary"
    
    # 验证是 Mach-O 文件
    file "$binary" | grep -q "Mach-O" || {
        echo "    SKIP: Not a Mach-O file"
        continue
    }
    
    # 复制 dylib 到 app 目录
    cp "$GITHUB_WORKSPACE/ByPass/TrollRecorderBypass.dylib" .
    
    # 注入 dylib
    python3 "$GITHUB_WORKSPACE/ByPass/inject_dylib.py" "$binary" "@executable_path/TrollRecorderBypass.dylib" "${binary}_patched" || {
        echo "    FAILED to inject dylib into $binary"
        continue
    }
    
    if [ -f "${binary}_patched" ]; then
        mv "${binary}_patched" "$binary"
        echo "    INJECTED: $binary"
    fi
done

# 清理临时文件
rm -f TrollRecorderBypass.dylib 2>/dev/null || true

# 5. 重新签名所有二进制文件
echo ""
echo "[5/6] Re-signing binaries..."

# 签名 dylib
cp "$GITHUB_WORKSPACE/ByPass/TrollRecorderBypass.dylib" .
echo "  Signing: TrollRecorderBypass.dylib"
ldid -S TrollRecorderBypass.dylib 2>&1 || echo "  WARNING: ldid sign failed for dylib"

# 签名主二进制和守护进程
for binary in $BINARIES; do
    if [ -f "$binary" ]; then
        echo "  Signing: $binary"
        ldid -S "$binary" 2>&1 || echo "  WARNING: ldid sign failed for $binary"
    fi
done

# 签名 PlugIns
if [ -d "PlugIns" ]; then
    for plug in PlugIns/*.appex; do
        if [ -d "$plug" ]; then
            plug_name=$(basename "$plug" .appex)
            if [ -f "$plug/$plug_name" ]; then
                echo "  Signing: $plug_name"
                ldid -S "$plug/$plug_name" 2>&1 || true
            fi
        fi
    done
fi

# 6. 重新打包
echo ""
echo "[6/6] Repackaging as .tipa..."
cd "$GITHUB_WORKSPACE/ByPass"
cd extracted
ditto -c -k --sequesterRsrc --keepParent Payload ../TRApp_ByPass.tipa
cd ..

echo ""
echo "=== Done! ==="
ls -la TRApp_ByPass.tipa
echo ""
echo "v7 Dylib: Hooks SecItemCopyMatching + SecItemAdd + patches all verification methods"
echo "All Keychain reads for wiki.qaq.trapp will return fake valid license data"
echo "All verification methods on TR*/Keychain/Payment/License/etc classes patched to pass"