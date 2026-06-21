#!/bin/bash
# ============================================================
#  CallRecorder 一键设置脚本
#  在 Mac 上运行此脚本完成项目初始化
# ============================================================

set -e

echo "============================================"
echo "  CallRecorder 项目初始化"
echo "============================================"

# 检查 XcodeGen
if ! command -v xcodegen &> /dev/null; then
    echo "正在安装 XcodeGen..."
    brew install xcodegen
fi

# 生成 Xcode 项目
echo "[1/3] 生成 Xcode 项目..."
xcodegen generate

# 生成静音音频资源（用于后台保活）
echo "[2/3] 生成静音音频资源..."
python3 -c "
import struct, wave, math
duration = 10  # 秒
sample_rate = 44100
samples = int(duration * sample_rate)
data = struct.pack('<' + 'h' * samples, *[0] * samples)
with wave.open('Resources/silence.wav', 'w') as f:
    f.setnchannels(1)
    f.setsampwidth(2)
    f.setframerate(sample_rate)
    f.writeframes(data)
" 2>/dev/null || echo "警告: 无法生成静音音频，应用将自动使用代码生成"

# 复制 mcc.txt 资源文件
echo "[3/3] 配置资源..."
if [ -f "../TRApp_2.14-542/extracted/Payload/TRApp.app/mcc.txt" ]; then
    cp "../TRApp_2.14-542/extracted/Payload/TRApp.app/mcc.txt" Resources/ 2>/dev/null || true
fi

echo ""
echo "============================================"
echo "  初始化完成!"
echo "  用 Xcode 打开 CallRecorder.xcodeproj"
echo "============================================"
echo ""
echo "构建 .tipa:"
echo "  bash Scripts/build.sh"
echo "============================================"