#!/bin/bash
# TrollRecorder 验证绕过打包脚本 v19
# 双重策略：静态二进制 Patch (方案1) + fishhook C 层 hook (方案2)
#
# 方案1: binary_patch.py - ARM64 指令级 patch，直接修改 TRApp 二进制
#   - 搜索 __cstring 中的验证函数名字符串引用
#   - 在函数入口替换为 MOV X0,#1; RET stub
# 方案2: TrollRecorderBypass_c.dylib - 纯 C dylib + fishhook
#   - constructor(101) 高优先级加载
#   - hook SecItemCopyMatching / SecItemAdd (Keychain)
#   - hook MGCopyAnswerWithError (设备信息)
#   - hook sysctlbyname (越狱检测)
#   - hook getenv (环境变量)
#   - hook NSClassFromString / objc_getClass (类查询)
# 保留: TrollRecorderBypass.dylib (ObjC 完整版) + TrollRecorderBypassSafe.dylib

set -e

echo "============================================================"
echo "  TrollRecorder Bypass v19"
echo "  Dual Strategy: Binary Patch (ARM64) + fishhook C hooks"
echo "============================================================"
echo "Date: $(date)"
echo ""

GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
BYPASS_DIR="$GITHUB_WORKSPACE/ByPass"
if [ ! -d "$BYPASS_DIR" ]; then
    BYPASS_DIR="$(pwd)"
fi

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN_IOS="14.0"

# ============================================================
# 1. 解压原始 .tipa
# ============================================================
echo "[1/8] Extracting original .tipa..."
python3 -c "
import zipfile
with zipfile.ZipFile('TRApp_2.14-542.tipa', 'r') as zf:
    zf.extractall('extracted')
print('Extraction complete')
"

# ============================================================
# 2. 安装 ldid
# ============================================================
echo ""
echo "[2/8] Installing ldid..."
if ! command -v ldid &> /dev/null; then
    brew install ldid 2>/dev/null || {
        curl -sL https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_macosx_x86_64 -o /usr/local/bin/ldid
        chmod +x /usr/local/bin/ldid
    }
fi
ldid --version 2>/dev/null || echo "ldid installed"

# ============================================================
# 3. 编译 dylibs (方案2: fishhook C dylib + 原有 ObjC dylibs)
# ============================================================
echo ""

# 3a. 编译 TrollRecorderBypass_c.dylib (方案2: 纯 C + fishhook)
echo "[3a/8] Compiling TrollRecorderBypass_c.dylib (Scheme 2: C + fishhook)..."
FISHHOOK_C="$BYPASS_DIR/fishhook.c"
BYPASS_C="$BYPASS_DIR/TrollRecorderBypass_c.c"

if [ ! -f "$FISHHOOK_C" ]; then
    echo "ERROR: fishhook.c not found at $FISHHOOK_C"
    exit 1
fi
if [ ! -f "$BYPASS_C" ]; then
    echo "ERROR: TrollRecorderBypass_c.c not found at $BYPASS_C"
    exit 1
fi

clang -arch arm64 -dynamiclib \
    -framework Foundation \
    -framework Security \
    -framework CoreFoundation \
    -framework UIKit \
    -isysroot "$SDK_PATH" \
    -miphoneos-version-min="$MIN_IOS" \
    -fobjc-arc \
    -I"$SDK_PATH/usr/include" \
    -I"$BYPASS_DIR" \
    -o TrollRecorderBypass_c.dylib \
    "$BYPASS_C" \
    "$FISHHOOK_C"

if [ ! -f TrollRecorderBypass_c.dylib ]; then
    echo "ERROR: Failed to compile TrollRecorderBypass_c.dylib"
    exit 1
fi
echo "  TrollRecorderBypass_c.dylib compiled: $(file TrollRecorderBypass_c.dylib)"
echo "  Size: $(stat -f%z TrollRecorderBypass_c.dylib) bytes"

# 3b. 编译 ObjC 完整版 dylib (保留原有方案)
echo ""
echo "[3b/8] Compiling TrollRecorderBypass.dylib (ObjC enhanced, full hooks)..."
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
    -isysroot "$SDK_PATH" \
    -miphoneos-version-min="$MIN_IOS" \
    -fobjc-arc \
    -I"$SDK_PATH/usr/include" \
    -o TrollRecorderBypass.dylib \
    "$SOURCE_FILE"

if [ ! -f TrollRecorderBypass.dylib ]; then
    echo "ERROR: Failed to compile TrollRecorderBypass.dylib"
    exit 1
fi
echo "  TrollRecorderBypass.dylib compiled: $(file TrollRecorderBypass.dylib)"
echo "  Size: $(stat -f%z TrollRecorderBypass.dylib) bytes"

# 3c. 编译最小安全诊断版 dylib
echo ""
echo "[3c/8] Compiling TrollRecorderBypassSafe.dylib (minimal diagnostic)..."
SAFE_SOURCE="$BYPASS_DIR/TrollRecorderBypass_safe.m"
if [ ! -f "$SAFE_SOURCE" ]; then
    echo "ERROR: TrollRecorderBypass_safe.m not found at $SAFE_SOURCE"
    exit 1
fi
clang -arch arm64 -dynamiclib \
    -framework Foundation \
    -isysroot "$SDK_PATH" \
    -miphoneos-version-min="$MIN_IOS" \
    -fobjc-arc \
    -I"$SDK_PATH/usr/include" \
    -o TrollRecorderBypassSafe.dylib \
    "$SAFE_SOURCE"

if [ ! -f TrollRecorderBypassSafe.dylib ]; then
    echo "ERROR: Failed to compile TrollRecorderBypassSafe.dylib"
    exit 1
fi
echo "  TrollRecorderBypassSafe.dylib compiled: $(file TrollRecorderBypassSafe.dylib)"
echo "  Size: $(stat -f%z TrollRecorderBypassSafe.dylib) bytes"

# ============================================================
# 4. 方案1: 静态二进制 Patch (ARM64 指令级)
# ============================================================
echo ""
echo "[4/8] Scheme 1: Static binary patch (ARM64 instruction-level)..."

cd "extracted/Payload/TRApp.app"

# 对 TRApp 主二进制做指令级 patch
if [ -f "TRApp" ]; then
    echo "  Patching TRApp with binary_patch.py..."
    
    # 备份
    cp TRApp TRApp.orig
    
    python3 "$BYPASS_DIR/binary_patch.py" TRApp -o TRApp_patched 2>&1 || {
        echo "  WARNING: binary_patch.py failed, keeping original"
        cp TRApp.orig TRApp
    }
    
    if [ -f TRApp_patched ]; then
        mv TRApp_patched TRApp
        echo "  TRApp patched successfully"
    else
        echo "  WARNING: TRApp_patched not generated, keeping original"
        cp TRApp.orig TRApp
    fi
    
    rm -f TRApp.orig
else
    echo "  TRApp binary not found, skipping instruction-level patch"
fi

cd "$BYPASS_DIR"

# ============================================================
# 5. dylib 注入 (方案2 C dylib + 原有 dylibs)
# ============================================================
echo ""
echo "[5/8] Injecting dylibs..."

cd "extracted/Payload/TRApp.app"

# 复制所有 dylib 到 app bundle
echo "  Copying dylibs to app bundle..."
cp "$BYPASS_DIR/TrollRecorderBypass_c.dylib" . 2>/dev/null || {
    echo "  ERROR: Cannot find TrollRecorderBypass_c.dylib"
    exit 1
}
cp "$BYPASS_DIR/TrollRecorderBypass.dylib" . 2>/dev/null || {
    echo "  ERROR: Cannot find TrollRecorderBypass.dylib"
    exit 1
}
cp "$BYPASS_DIR/TrollRecorderBypassSafe.dylib" . 2>/dev/null || {
    echo "  ERROR: Cannot find TrollRecorderBypassSafe.dylib"
    exit 1
}
echo "  All dylibs copied:"
ls -la *.dylib 2>/dev/null

# 要注入的二进制列表
BINARIES="TRApp TRCallMonitor TRAudioRecorder TRCallRecorder TRSyncLite TRVoiceMemo TRAudioPlayer TRSpeechUtterance"

for binary in $BINARIES; do
    if [ ! -f "$binary" ]; then
        continue
    fi
    
    echo ""
    echo "  Processing: $binary"
    
    file "$binary" | grep -q "Mach-O" || {
        echo "    SKIP: Not a Mach-O file"
        continue
    }
    
    # 备份
    cp "$binary" "${binary}.orig"
    
    # 注入方案2 C dylib (弱链接)
    python3 "$BYPASS_DIR/inject_dylib.py" "$binary" \
        "@executable_path/TrollRecorderBypass_c.dylib" \
        "${binary}_patched" || {
        echo "    C dylib injection FAILED, keeping original"
        cp "${binary}.orig" "$binary"
        rm -f "${binary}_patched"
        continue
    }
    
    if [ -f "${binary}_patched" ]; then
        mv "${binary}_patched" "$binary"
        echo "    INJECTED (C dylib): $binary"
        
        otool -L "$binary" | grep -i "TrollRecorderBypass" && \
            echo "    Verify: dylib(s) in load commands" || \
            echo "    Verify: WARNING - dylib not found"
        
        otool -l "$binary" > /dev/null 2>&1 && \
            echo "    Structure: OK" || {
            echo "    Structure: CORRUPTED! Restoring original"
            cp "${binary}.orig" "$binary"
        }
    else
        echo "    Injection failed, restoring original"
        cp "${binary}.orig" "$binary"
    fi
    
    rm -f "${binary}.orig"
done

# ============================================================
# 6. Info.plist LSEnvironment → 加载方案2 C dylib
# ============================================================
echo ""
echo "[6/8] Patching Info.plist LSEnvironment..."

# 方案2: C dylib 通过 LSEnvironment DYLD_INSERT_LIBRARIES 加载
python3 "$BYPASS_DIR/patch_plist.py" "Info.plist" \
    "@executable_path/TrollRecorderBypass_c.dylib"

echo "  LSEnvironment configured for C dylib"

# ============================================================
# 7. 重新签名
# ============================================================
echo ""
echo "[7/8] Re-signing all binaries..."

echo "  Signing: TrollRecorderBypass_c.dylib (Scheme 2)"
ldid -S TrollRecorderBypass_c.dylib 2>&1 || echo "  WARNING: ldid sign failed for C dylib"

echo "  Signing: TrollRecorderBypass.dylib"
ldid -S TrollRecorderBypass.dylib 2>&1 || echo "  WARNING: ldid sign failed"

echo "  Signing: TrollRecorderBypassSafe.dylib"
ldid -S TrollRecorderBypassSafe.dylib 2>&1 || echo "  WARNING: ldid sign failed"

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

# ============================================================
# 8. 重新打包
# ============================================================
echo ""
echo "[8/8] Repackaging as .tipa..."

cd "$BYPASS_DIR"
cd extracted
ditto -c -k --sequesterRsrc --keepParent Payload ../TRApp_ByPass.tipa
cd ..

echo ""
echo "============================================================"
echo "  Build Complete!"
echo "============================================================"
ls -la TRApp_ByPass.tipa
echo ""
echo "v19: Dual Strategy Bypass"
echo "  Scheme 1 (Binary Patch): ARM64 instruction-level patch on TRApp"
echo "    - __cstring xref search for verification function names"
echo "    - Entry point: MOV X0,#1; RET stubs"
echo "    - Target: checkCodeSignature, globalSetupApplication, ExecuteReceipt, etc."
echo ""
echo "  Scheme 2 (fishhook C hooks): TrollRecorderBypass_c.dylib"
echo "    - constructor(101) high-priority loading"
echo "    - SecItemCopyMatching / SecItemAdd (Keychain intercept)"
echo "    - MGCopyAnswerWithError (device info fake)"
echo "    - sysctlbyname (jailbreak detection bypass)"
echo "    - getenv (environment variable fake)"
echo "    - NSClassFromString / objc_getClass (class query intercept)"
echo "    - Diagnostic log: /tmp/bypass_c.log"
echo ""
echo "  Retained: TrollRecorderBypass.dylib (ObjC hooks)"
echo "  Retained: TrollRecorderBypassSafe.dylib (minimal diagnostic)"
