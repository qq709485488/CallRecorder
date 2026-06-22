#!/bin/bash
# TrollRecorder 验证绕过打包脚本 v11
# 修复：使用 insert_dylib 工具替代自定义 Python 脚本
# 原因：inject_dylib.py 插入 LC_LOAD_DYLIB 时未更新 segment fileoff，
#        导致二进制结构损坏，应用闪退
# insert_dylib 是 iOS 越狱社区标准工具，正确处理所有偏移量

set -e

echo "=== TrollRecorder Bypass v11 (insert_dylib tool) ==="
echo "Fix: Use insert_dylib instead of custom Python script"
echo "Date: $(date)"
echo ""

GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"

# 1. 解压原始 .tipa
echo "[1/7] Extracting original .tipa..."
python3 -c "
import zipfile
with zipfile.ZipFile('TRApp_2.14-542.tipa', 'r') as zf:
    zf.extractall('extracted')
print('Extraction complete')
"

# 2. 安装 ldid 和 insert_dylib
echo "[2/7] Installing tools..."
if ! command -v ldid &> /dev/null; then
    brew install ldid 2>/dev/null || {
        curl -sL https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_macosx_x86_64 -o /usr/local/bin/ldid
        chmod +x /usr/local/bin/ldid
    }
fi

# 编译 insert_dylib 工具（从源码）
if ! command -v insert_dylib &> /dev/null; then
    echo "  Building insert_dylib from source..."
    cd /tmp
    git clone https://github.com/Tyilo/insert_dylib.git 2>/dev/null || true
    cd insert_dylib
    git pull 2>/dev/null || true
    # insert_dylib 需要 macOS SDK 的头文件
    clang -o insert_dylib insert_dylib.c -I"$(xcrun --show-sdk-path)/usr/include" || {
        echo "  WARNING: Failed to compile insert_dylib, trying alternative..."
        # 备选：使用 optool
        cd /tmp
        git clone https://github.com/alexzielenski/optool.git 2>/dev/null || true
        cd optool
        git pull 2>/dev/null || true
        xcodebuild -project optool.xcodeproj -scheme optool -configuration Release build || {
            echo "  ERROR: Failed to build both insert_dylib and optool"
            exit 1
        }
        cp build/Release/optool /usr/local/bin/optool
        chmod +x /usr/local/bin/optool
        echo "  Using optool instead"
    }
    if [ -f /tmp/insert_dylib/insert_dylib ]; then
        cp /tmp/insert_dylib/insert_dylib /usr/local/bin/insert_dylib
        chmod +x /usr/local/bin/insert_dylib
        echo "  insert_dylib built successfully"
    fi
    cd "$GITHUB_WORKSPACE"
fi

which insert_dylib 2>/dev/null && echo "  insert_dylib: OK" || echo "  insert_dylib: NOT FOUND"
which optool 2>/dev/null && echo "  optool: OK" || echo "  optool: NOT FOUND"
which ldid 2>/dev/null && echo "  ldid: OK" || echo "  ldid: NOT FOUND"

# 3. 编译 dylib
echo ""
echo "[3/7] Compiling TrollRecorderBypass.dylib..."
clang -arch arm64 -dynamiclib \
    -framework Foundation \
    -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
    -miphoneos-version-min=14.0 \
    -fobjc-arc \
    -o TrollRecorderBypass.dylib \
    "$GITHUB_WORKSPACE/ByPass/TrollRecorderBypass.m"

if [ ! -f TrollRecorderBypass.dylib ]; then
    echo "ERROR: Failed to compile dylib"
    exit 1
fi
echo "Dylib compiled: $(file TrollRecorderBypass.dylib)"
echo "Dylib size: $(stat -f%z TrollRecorderBypass.dylib) bytes"

# 4. 验证原始二进制
echo ""
echo "[4/7] Verifying original binaries..."
cd "extracted/Payload/TRApp.app"

BINARIES="TRApp TRCallMonitor TRAudioRecorder TRCallRecorder TRSyncLite TRVoiceMemo TRAudioPlayer TRSpeechUtterance"

for binary in $BINARIES; do
    if [ ! -f "$binary" ]; then
        continue
    fi
    echo "  $binary: $(file "$binary" | sed 's/.*: //')"
    echo "    Size: $(stat -f%z "$binary") bytes"
    # 检查是否有足够的空间插入 load command
    otool -l "$binary" 2>/dev/null | grep -A2 "LC_SEGMENT_64" | head -6 || true
done

# 5. 使用 insert_dylib 注入（替代自定义 Python 脚本）
echo ""
echo "[5/7] Injecting dylib using insert_dylib..."

# 复制 dylib 到 app 目录
cp "$GITHUB_WORKSPACE/TrollRecorderBypass.dylib" .

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
    
    # 先备份
    cp "$binary" "${binary}.orig"
    
    # 方法1：使用 insert_dylib
    if command -v insert_dylib &> /dev/null; then
        echo "    Using insert_dylib..."
        insert_dylib --inplace --weak "@executable_path/TrollRecorderBypass.dylib" "$binary" 2>&1 || {
            echo "    insert_dylib failed, trying without --weak..."
            insert_dylib --inplace "@executable_path/TrollRecorderBypass.dylib" "$binary" 2>&1 || {
                echo "    insert_dylib FAILED, restoring original"
                cp "${binary}.orig" "$binary"
                continue
            }
        }
        echo "    INJECTED: $binary"
        
        # 验证注入结果
        otool -L "$binary" | grep -i "TrollRecorderBypass" && echo "    Verify: OK" || echo "    Verify: WARNING - dylib not found in load commands"
    # 方法2：使用 optool
    elif command -v optool &> /dev/null; then
        echo "    Using optool..."
        optool install -c load -p "@executable_path/TrollRecorderBypass.dylib" -t "$binary" 2>&1 || {
            echo "    optool FAILED, restoring original"
            cp "${binary}.orig" "$binary"
            continue
        }
        echo "    INJECTED: $binary"
        otool -L "$binary" | grep -i "TrollRecorderBypass" && echo "    Verify: OK" || echo "    Verify: WARNING"
    else
        echo "    ERROR: No injection tool available"
        cp "${binary}.orig" "$binary"
        continue
    fi
    
    # 验证二进制结构完整性
    echo "    Verifying binary structure..."
    otool -l "$binary" > /dev/null 2>&1 && echo "    Structure: OK" || echo "    Structure: WARNING - otool failed"
    
    # 清理备份
    rm -f "${binary}.orig"
done

# 6. 重新签名所有二进制文件
echo ""
echo "[6/7] Re-signing binaries..."

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

# 7. 重新打包
echo ""
echo "[7/7] Repackaging as .tipa..."
cd "$GITHUB_WORKSPACE"
cd extracted
ditto -c -k --sequesterRsrc --keepParent Payload ../TRApp_ByPass.tipa
cd ..

echo ""
echo "=== Done! ==="
ls -la TRApp_ByPass.tipa
echo ""
echo "v11: Uses insert_dylib tool (standard iOS community tool)"
echo "  - Correctly updates all Mach-O offsets (segment fileoff, etc.)"
echo "  - Previous versions used custom Python script that corrupted binaries"
echo "  - This is the root cause of all previous crashes"