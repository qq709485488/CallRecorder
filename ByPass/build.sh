#!/bin/bash
# TrollRecorder 验证绕过打包脚本 v13
# 策略：弱链接 + 移除旧签名 + 极简 dylib
# - LC_LOAD_WEAK_DYLIB：dylib 加载失败也不崩溃
# - 移除旧签名：ldid -S 从头签名，避免签名冲突
# - 极简 dylib：只做 UserDefaults 预设，不调用 runtime API
# 原因：v12 强链接导致 dylib 加载失败时崩溃，v13 改用弱链接

set -e

echo "=== TrollRecorder Bypass v18 (enhanced for account-based verification) ==="
echo "Strategy: NSURLProtocol + URLSession hook + Keychain + UserDefaults + PaymentManager + ASWebAuth"
echo "Date: $(date)"
echo ""

GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
BYPASS_DIR="$GITHUB_WORKSPACE/ByPass"
# 如果 ByPass 目录不存在（本地运行），使用当前目录
if [ ! -d "$BYPASS_DIR" ]; then
    BYPASS_DIR="$(pwd)"
fi

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

# 3. 编译 dylib (v18 增强版)
echo ""
echo "[3/6] Compiling TrollRecorderBypass.dylib (v18 enhanced)..."
# 优先编译 v17（v18增强版），回退到旧版
SOURCE_FILE="$BYPASS_DIR/TrollRecorderBypass_v17.m"
if [ ! -f "$SOURCE_FILE" ]; then
    SOURCE_FILE="$BYPASS_DIR/TrollRecorderBypass.m"
    echo "  Using legacy source: $SOURCE_FILE"
else
    echo "  Using v18 enhanced source: $SOURCE_FILE"
fi
clang -arch arm64 -dynamiclib \
    -framework Foundation \
    -framework Security \
    -framework UIKit \
    -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
    -miphoneos-version-min=14.0 \
    -fobjc-arc \
    -I"$(xcrun --sdk iphoneos --show-sdk-path)/usr/include" \
    -o TrollRecorderBypass.dylib \
    "$SOURCE_FILE"

if [ ! -f TrollRecorderBypass.dylib ]; then
    echo "ERROR: Failed to compile dylib"
    exit 1
fi
echo "Dylib compiled: $(file TrollRecorderBypass.dylib)"
echo "Dylib size: $(stat -f%z TrollRecorderBypass.dylib) bytes"

# 4. 使用修复后的 inject_dylib.py 注入
echo ""
echo "[4/6] Injecting dylib (padding-based, no data shifting)..."

cd "extracted/Payload/TRApp.app"

# 复制 dylib 到 app 目录
cp "$BYPASS_DIR/TrollRecorderBypass.dylib" . 2>/dev/null || cp TrollRecorderBypass.dylib . 2>/dev/null || {
    echo "  ERROR: Cannot find TrollRecorderBypass.dylib"
    echo "  Looking in: $BYPASS_DIR/ and current dir"
    ls -la "$BYPASS_DIR/"*.dylib 2>/dev/null || true
    ls -la ./*.dylib 2>/dev/null || true
    exit 1
}

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
    
    # 备份
    cp "$binary" "${binary}.orig"
    
    # 使用修复后的 Python 脚本注入（弱链接，dylib 加载失败也不崩溃）
    python3 "$BYPASS_DIR/inject_dylib.py" "$binary" "@executable_path/TrollRecorderBypass.dylib" "${binary}_patched" || {
        echo "    Injection FAILED, keeping original"
        cp "${binary}.orig" "$binary"
        rm -f "${binary}_patched"
        continue
    }
    
    # 检查 patched 文件
    if [ -f "${binary}_patched" ]; then
        mv "${binary}_patched" "$binary"
        echo "    INJECTED: $binary"
        
        # 验证注入结果
        otool -L "$binary" | grep -i "TrollRecorderBypass" && echo "    Verify: dylib in load commands" || echo "    Verify: WARNING - dylib not found"
        
        # 验证二进制结构完整性
        otool -l "$binary" > /dev/null 2>&1 && echo "    Structure: OK" || {
            echo "    Structure: CORRUPTED! Restoring original"
            cp "${binary}.orig" "$binary"
        }
    else
        echo "    Injection failed, restoring original"
        cp "${binary}.orig" "$binary"
    fi
    
    rm -f "${binary}.orig"
done

# 4.5. 使用 patch_plist.py 注入 LSEnvironment（TrollStore DYLD_INSERT_LIBRARIES）
echo ""
echo "[4.5/6] Patching Info.plist LSEnvironment..."
python3 "$BYPASS_DIR/patch_plist.py" "Info.plist" "@executable_path/TrollRecorderBypass.dylib"

# 5. 重新签名所有二进制文件
echo ""
echo "[5/6] Re-signing binaries..."

echo "  Signing: TrollRecorderBypass.dylib"
ldid -S TrollRecorderBypass.dylib 2>&1 || echo "  WARNING: ldid sign failed for dylib"

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
cd "$BYPASS_DIR"
cd extracted
ditto -c -k --sequesterRsrc --keepParent Payload ../TRApp_ByPass.tipa
cd ..

echo ""
echo "=== Done! ==="
ls -la TRApp_ByPass.tipa
echo ""
echo "v18: Enhanced bypass for account-based verification"
echo "  - NSURLProtocol intercepts DRM server responses"
echo "  - NSURLSession hook intercepts Havoc API"
echo "  - PaymentManager, CloudService, DeviceInfo patches"
echo "  - ASWebAuthenticationSession bypass"
echo "  - Keychain + UserDefaults + FeatureFlagStore hooks"
echo "  - Diagnostic logging to /tmp/bypass.log"