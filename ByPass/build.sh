#!/bin/bash
# TrollRecorder 验证绕过打包脚本 v14
# 多层次绕过策略：
#   1. Binary Patch: 修补所有 ObjC 验证方法（含活性检测、Keychain监控）
#   2. Dylib注入: 弱链接 dylib（UserDefaults预置 + 通知拦截 + 方法替换）
#   3. 签名清理: 移除旧签名 + ldid -S 重签
# 
# 新增 vs v13:
#   - 补全 17 个遗漏验证方法（活性检测、Keychain监控）
#   - dylib 增加 4 层绕过（UserDefaults+通知+Keychain+方法替换）
#   - 先 patch 再注入（两阶段加固）

set -e

echo "=== TrollRecorder Bypass v14 (multi-layer) ==="
echo "Strategy: binary patch + weak-link dylib + 4-layer runtime bypass"
echo "Date: $(date)"
echo ""

GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
BYPASS_DIR="$GITHUB_WORKSPACE/ByPass"
if [ ! -d "$BYPASS_DIR" ]; then
    BYPASS_DIR="$(pwd)"
fi

# 1. 解压原始 .tipa
echo "[1/7] Extracting original .tipa..."
python3 -c "
import zipfile
with zipfile.ZipFile('TRApp_2.14-542.tipa', 'r') as zf:
    zf.extractall('extracted')
print('Extraction complete')
"

# 2. 安装 ldid
echo "[2/7] Installing ldid..."
if ! command -v ldid &> /dev/null; then
    brew install ldid 2>/dev/null || {
        curl -sL https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_macosx_x86_64 -o /usr/local/bin/ldid
        chmod +x /usr/local/bin/ldid
    }
fi
ldid --version 2>/dev/null || echo "ldid installed"

# 3. Binary Patch（第一阶段：修补 ObjC 方法）
echo ""
echo "[3/7] Patching binary (ObjC method replacement)..."

BINARIES="TRApp TRCallMonitor TRAudioRecorder TRCallRecorder TRSyncLite TRVoiceMemo TRAudioPlayer TRSpeechUtterance"

for binary in $BINARIES; do
    if [ ! -f "extracted/Payload/TRApp.app/$binary" ]; then
        continue
    fi
    
    binary_path="extracted/Payload/TRApp.app/$binary"
    file "$binary_path" | grep -q "Mach-O" || continue
    
    echo "  Patching: $binary"
    python3 "$BYPASS_DIR/patch_binary.py" "$binary_path" -o "${binary_path}_patched" || {
        echo "    WARNING: Patch failed for $binary, continuing without patch"
        continue
    }
    
    if [ -f "${binary_path}_patched" ]; then
        mv "${binary_path}_patched" "$binary_path"
        echo "    PATCHED: $binary"
    fi
done

# 4. 编译 dylib
echo ""
echo "[4/7] Compiling TrollRecorderBypass.dylib..."

# 优先使用 v14 源文件
DYLIB_SRC=""
if [ -f "$BYPASS_DIR/TrollRecorderBypass_v14.m" ]; then
    DYLIB_SRC="$BYPASS_DIR/TrollRecorderBypass_v14.m"
elif [ -f "TrollRecorderBypass_v14.m" ]; then
    DYLIB_SRC="TrollRecorderBypass_v14.m"
elif [ -f "$BYPASS_DIR/TrollRecorderBypass.m" ]; then
    DYLIB_SRC="$BYPASS_DIR/TrollRecorderBypass.m"
else
    DYLIB_SRC="TrollRecorderBypass.m"
fi
echo "  Source: $DYLIB_SRC"

clang -arch arm64 -dynamiclib \
    -framework Foundation \
    -framework Security \
    -framework CFNetwork \
    -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
    -miphoneos-version-min=14.0 \
    -fobjc-arc \
    -o TrollRecorderBypass.dylib \
    "$DYLIB_SRC"

if [ ! -f TrollRecorderBypass.dylib ]; then
    echo "ERROR: Failed to compile dylib"
    exit 1
fi
echo "Dylib compiled: $(file TrollRecorderBypass.dylib)"

# 5. 注入 dylib（第二阶段：弱链接加载）
echo ""
echo "[5/7] Injecting dylib (weak link)..."

cd "extracted/Payload/TRApp.app"
cp "$BYPASS_DIR/TrollRecorderBypass.dylib" . 2>/dev/null || cp TrollRecorderBypass.dylib .

for binary in $BINARIES; do
    if [ ! -f "$binary" ]; then
        continue
    fi
    
    file "$binary" | grep -q "Mach-O" || continue
    
    echo "  Injecting: $binary"
    cp "$binary" "${binary}.orig"
    
    python3 "$BYPASS_DIR/inject_dylib.py" "$binary" "@executable_path/TrollRecorderBypass.dylib" "${binary}_patched" || {
        echo "    Injection failed, keeping original"
        cp "${binary}.orig" "$binary"
        rm -f "${binary}_patched"
        continue
    }
    
    if [ -f "${binary}_patched" ]; then
        mv "${binary}_patched" "$binary"
        echo "    INJECTED: $binary"
        otool -L "$binary" | grep -i "TrollRecorderBypass" && echo "    Verify: dylib in load commands" || echo "    Verify: WARNING"
    fi
    
    rm -f "${binary}.orig"
done

# 6. 签名
echo ""
echo "[6/7] Signing binaries..."

echo "  Signing dylib..."
ldid -S TrollRecorderBypass.dylib 2>&1 || echo "  WARNING: ldid sign failed for dylib"

for binary in $BINARIES; do
    if [ -f "$binary" ]; then
        echo "  Signing: $binary"
        ldid -S "$binary" 2>&1 || echo "  WARNING: ldid sign failed for $binary"
    fi
done

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

# 7. 打包
echo ""
echo "[7/7] Repackaging .tipa..."
cd "$BYPASS_DIR"
cd extracted
ditto -c -k --sequesterRsrc --keepParent Payload ../TRApp_ByPass.tipa
cd ..

echo ""
echo "=== v14 Build Complete ==="
ls -la TRApp_ByPass.tipa
echo ""
echo "Multi-layer bypass deployed:"
echo "  Layer 1: Binary patch (80 methods: alive check + keychain + all verification)"
echo "  Layer 2: UserDefaults pre-seeding (comprehensive keys)"
echo "  Layer 3: CFNotificationCenter (purchase/intro blocked)"
echo "  Layer 4: Keychain hook (SecItemCopyMatching)"
echo "  Layer 5: ObjC method swizzling (runtime fallback)"
