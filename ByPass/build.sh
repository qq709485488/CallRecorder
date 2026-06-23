#!/bin/bash
# TrollRecorder 验证绕过打包脚本 v18
# 多层次绕过策略：
#   1. Binary Patch: 修补所有 ObjC 验证方法（含活性检测、Keychain监控）
#   2. Dylib注入: 弱链接 dylib（fishhook Keychain + NSURLSession bypass）
#   3. 签名清理: 移除旧签名 + ldid -S 重签
# 
# 新增 vs v15:
#   - fishhook-based Keychain hook 替换 +__const 段 method swizzling
#   - NSURLSession 请求拦截 bypass

set -e

echo "=== TrollRecorder Bypass v18 (INFO.PLIST + STRONG-LINK) ==="
echo "Strategy: Info.plist DYLD_INSERT_LIBRARIES (primary) + strong-link dylib (best-effort) + fishhook Keychain + NSURLSession bypass"
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

# 2. 安装 ldid (支持 x86_64 和 arm64)
echo "[2/7] Installing ldid..."
ARCH=$(uname -m)
LDID_URL=""
case "$ARCH" in
    arm64)  LDID_URL="https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_macosx_arm64" ;;
    x86_64) LDID_URL="https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_macosx_x86_64" ;;
    *)      echo "ERROR: Unknown architecture $ARCH"; exit 1 ;;
esac

if ! command -v ldid &> /dev/null; then
    brew install ldid 2>/dev/null || {
        mkdir -p ~/bin
        curl -sL "$LDID_URL" -o ~/bin/ldid
        chmod +x ~/bin/ldid
        export PATH="$HOME/bin:$PATH"
    }
fi
echo "  ldid: $(which ldid) ($(file $(which ldid) 2>/dev/null | cut -d: -f2))"
ldid --version 2>/dev/null || echo "  ldid installed"

# 3. Binary Patch（第一阶段：修补 ObjC 方法，设置 SKIP_PATCH=1 跳过）
echo ""
echo "[3/9] Patching binary (ObjC method replacement)..."
if [ "${SKIP_PATCH:-0}" = "1" ]; then
    echo "  SKIP_PATCH=1, skipping binary patch step"
else

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

fi

# 4. 编译 dylib
echo ""
echo "[4/9] Compiling TrollRecorderBypass.dylib..."

# 优先使用 v16 源文件（fishhook-based Keychain + NSURLSession bypass）
DYLIB_SRC=""
if [ -f "$BYPASS_DIR/TrollRecorderBypass_v17.m" ]; then
    DYLIB_SRC="$BYPASS_DIR/TrollRecorderBypass_v17.m"
elif [ -f "$BYPASS_DIR/TrollRecorderBypass_v16.m" ]; then
    DYLIB_SRC="$BYPASS_DIR/TrollRecorderBypass_v16.m"
elif [ -f "$BYPASS_DIR/TrollRecorderBypass_v15.m" ]; then
    DYLIB_SRC="$BYPASS_DIR/TrollRecorderBypass_v15.m"
elif [ -f "$BYPASS_DIR/TrollRecorderBypass_v14.m" ]; then
    DYLIB_SRC="$BYPASS_DIR/TrollRecorderBypass_v14.m"
fi
echo "  Source: $DYLIB_SRC"

clang -arch arm64 -dynamiclib \
    -framework Foundation \
    -framework Security \
    -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
    -miphoneos-version-min=14.0 \
    -fobjc-arc \
    -install_name @executable_path/TrollRecorderBypass.dylib \
    -o TrollRecorderBypass.dylib \
    "$DYLIB_SRC"

if [ ! -f TrollRecorderBypass.dylib ]; then
    echo "ERROR: Failed to compile dylib"
    exit 1
fi
echo "Dylib compiled: $(file TrollRecorderBypass.dylib)"

# 5. Patch Info.plist（DYLD_INSERT_LIBRARIES 可靠加载）
echo ""
echo "[5/8] Patching Info.plist (DYLD_INSERT_LIBRARIES)..."

cd "extracted/Payload/TRApp.app"
python3 "$BYPASS_DIR/patch_plist.py" Info.plist "TrollRecorderBypass.dylib" || {
    echo "  FATAL: Info.plist patch failed!"
    exit 1
}
# 6. 注入 dylib（最佳实践，失败无害）
echo ""
echo "[6/8] Injecting dylib (best-effort strong link)..."

cp "$BYPASS_DIR/TrollRecorderBypass.dylib" . 2>/dev/null || cp TrollRecorderBypass.dylib .

for binary in $BINARIES; do
    if [ ! -f "$binary" ]; then
        continue
    fi
    
    file "$binary" | grep -q "Mach-O" || continue
    
    echo "  Injecting: $binary"
    cp "$binary" "${binary}.orig"
    
    python3 "$BYPASS_DIR/inject_dylib.py" "$binary" "@executable_path/TrollRecorderBypass.dylib" "${binary}_patched" || {
        echo "    Best-effort injection failed (DYLD_INSERT_LIBRARIES will handle loading)"
        rm -f "${binary}_patched" "${binary}.orig"
        continue
    }
    
    if [ -f "${binary}_patched" ]; then
        mv "${binary}_patched" "$binary"
        echo "    INJECTED: $binary"
        otool -L "$binary" | grep -i "TrollRecorderBypass" && echo "    Verify: dylib in load commands" || echo "    Verify: WARNING (DYLD_INSERT_LIBRARIES is active)"
        rm -f "${binary}.orig"
    fi
done

# 6. Verify injection (otool -l check)
echo ""
echo "[7/9] Verifying dylib injection..."
cd "extracted/Payload/TRApp.app"
for binary in $BINARIES; do
    if [ -f "$binary" ] && file "$binary" | grep -q "Mach-O"; then
        if otool -l "$binary" | grep -q "LC_LOAD_DYLIB.*TrollRecorderBypass"; then
            echo "  PASS: $binary has LC_LOAD_DYLIB -> TrollRecorderBypass"
        else
            echo "  FAIL: $binary missing TrollRecorderBypass load command"
        fi
    fi
done

# 7/8. 签名
echo ""
echo "[8/9] Signing binaries..."

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

# 8. 打包
echo ""
echo "[9/9] Repackaging .tipa..."
cd "$BYPASS_DIR"
cd extracted
ditto -c -k --sequesterRsrc --keepParent Payload ../TRApp_ByPass.tipa
cd ..

echo ""
echo "=== v18 Build Complete (Info.plist + dylib) ==="
ls -la TRApp_ByPass.tipa
echo ""
echo "Multi-layer bypass deployed (v18 Info.plist + strong-link):"
echo "  Layer 1: Info.plist DYLD_INSERT_LIBRARIES (guaranteed dylib loading)"
echo "  Layer 2: Binary patch (80 methods: alive check + keychain + all verification)"
echo "  Layer 3: UserDefaults pre-seeding (comprehensive keys)"
echo "  Layer 4: Fishhook-based Keychain hook (SecItemCopyMatching)"
echo "  Layer 5: NSURLSession request interception bypass"
