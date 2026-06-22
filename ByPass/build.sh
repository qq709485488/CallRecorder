#!/bin/bash
# TrollRecorder 验证绕过打包脚本 v12
# 修复：1) 注入前移除旧签名，ldid -S 重新签名
#       2) 改回 LC_LOAD_DYLIB（强链接）
#       3) 加回方法替换逻辑（C 函数 IMP + pthread 延迟）
# 原因：v11 的弱链接导致 dylib 未加载，旧签名未移除导致签名无效

set -e

echo "=== TrollRecorder Bypass v12 (remove sig + strong link + method patch) ==="
echo "Fix: Remove old signature before injection, use LC_LOAD_DYLIB, add method patching"
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

# 3. 编译 dylib
echo ""
echo "[3/6] Compiling TrollRecorderBypass.dylib..."
clang -arch arm64 -dynamiclib \
    -framework Foundation \
    -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
    -miphoneos-version-min=14.0 \
    -fobjc-arc \
    -I"$(xcrun --sdk iphoneos --show-sdk-path)/usr/include" \
    -o TrollRecorderBypass.dylib \
    "$BYPASS_DIR/TrollRecorderBypass.m"

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
echo "v12: Remove old signature + LC_LOAD_DYLIB + method patching"
echo "  - Removes old code signature before injection (fixes 'invalid signature')"
echo "  - Uses LC_LOAD_DYLIB (strong link, not weak)"
echo "  - C function IMPs for method patching (no PAC issues)"
echo "  - pthread delayed patching (5s after launch)"
echo "  - ldid -S re-signs everything cleanly"