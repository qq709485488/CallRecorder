#!/bin/bash
# TrollRecorder 验证移除打包脚本 v3
# 新方案：使用 otool 分析 ObjC 元数据，精确定位并修补所有验证方法
# 在 GitHub Actions macOS 环境中运行

set -e

echo "=== TrollRecorder Binary Patcher v4 ==="
echo "Strategy: Use otool to find ALL verification methods, then binary patch"
echo "Target: Original TRApp_2.14-542"
echo "Date: $(date)"
echo ""

GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"

# 1. 解压原始 .tipa
echo "[1/5] Extracting original .tipa..."
python3 -c "
import zipfile
with zipfile.ZipFile('TRApp_2.14-542.tipa', 'r') as zf:
    zf.extractall('extracted')
print('Extraction complete')
"

# 2. 安装 ldid
echo "[2/5] Installing ldid..."
if ! command -v ldid &> /dev/null; then
    brew install ldid 2>/dev/null || {
        curl -sL https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_macosx_x86_64 -o /usr/local/bin/ldid
        chmod +x /usr/local/bin/ldid
    }
fi

cd "extracted/Payload/TRApp.app"

# 3. 分析并修补二进制文件
echo "[3/5] Analyzing and patching binaries..."

# 要处理的二进制文件列表
BINARIES="TRApp TRCallMonitor TRAudioRecorder TRCallRecorder TRSyncLite TRVoiceMemo TRAudioPlayer TRSpeechUtterance"

for binary in $BINARIES; do
    if [ ! -f "$binary" ]; then
        continue
    fi
    
    echo ""
    echo "============================================"
    echo "Processing: $binary"
    echo "============================================"
    
    # 验证是 Mach-O 文件
    file "$binary" | grep -q "Mach-O" || {
        echo "  SKIP: Not a Mach-O file"
        continue
    }
    
    # 使用 otool 导出所有 ObjC 类信息
    echo "  Dumping ObjC class info..."
    otool -ov "$binary" > "/tmp/${binary}_objc_dump.txt" 2>&1 || true
    
    # 用 Python 分析 otool 输出，找到验证方法并生成补丁列表
    echo "  Analyzing verification methods..."
    python3 "$GITHUB_WORKSPACE/ByPass/analyze_otool.py" "/tmp/${binary}_objc_dump.txt" "$binary" "/tmp/${binary}_patches.txt" || true
    
    # 应用补丁
    if [ -s "/tmp/${binary}_patches.txt" ]; then
        echo "  Applying patches..."
        python3 "$GITHUB_WORKSPACE/ByPass/apply_patches.py" "$binary" "/tmp/${binary}_patches.txt" "${binary}_patched" || true
        
        if [ -f "${binary}_patched" ]; then
            mv "${binary}_patched" "$binary"
            echo "  PATCHED: $binary"
        else
            echo "  ERROR: Failed to produce patched binary"
        fi
    else
        echo "  No verification methods found in $binary (or all already patched)"
    fi
done

# 4. 重新签名所有二进制文件
echo ""
echo "[4/5] Re-signing binaries..."
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

# 5. 重新打包
echo ""
echo "[5/5] Repackaging as .tipa..."
cd "$GITHUB_WORKSPACE/ByPass"
cd extracted
ditto -c -k --sequesterRsrc --keepParent Payload ../TRApp_ByPass.tipa
cd ..

echo ""
echo "=== Done! ==="
ls -la TRApp_ByPass.tipa
echo ""
echo "Verification methods have been binary-patched to always return 'pass'."
echo "No dylib injection - pure binary modification."