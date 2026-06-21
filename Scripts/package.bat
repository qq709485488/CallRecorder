@echo off
REM ============================================================
REM  CallRecorder Windows 打包脚本
REM  将编译好的 .app 打包为 .tipa（巨魔安装格式）
REM ============================================================

setlocal enabledelayedexpansion

set "OUTPUT_DIR=%~dp0output"
set "APP_NAME=TRApp"

echo ============================================
echo   CallRecorder .tipa 打包工具
echo ============================================

REM 清理输出目录
if exist "%OUTPUT_DIR%" rmdir /s /q "%OUTPUT_DIR%"
mkdir "%OUTPUT_DIR%\tipa\Payload"

REM 检查 .app 是否存在
if not exist "Payload\%APP_NAME%.app" (
    echo [错误] 找不到 Payload\%APP_NAME%.app
    echo.
    echo 请先将编译好的 TRApp.app 放到 Payload 目录下：
    echo   CallRecorder\Payload\TRApp.app\
    echo.
    echo 编译方式：
    echo   1. 在 Mac 上运行: bash Scripts\build.sh
    echo   2. 或通过 GitHub Actions 自动编译（推送到 GitHub）
    echo.
    pause
    exit /b 1
)

REM 复制 .app 到 tipa 结构
echo [1/2] 复制 TRApp.app...
xcopy /e /i /q "Payload\%APP_NAME%.app" "%OUTPUT_DIR%\tipa\Payload\%APP_NAME%.app"

REM 打包为 zip（.tipa 格式）
echo [2/2] 打包为 .tipa...
powershell -Command "Compress-Archive -Path '%OUTPUT_DIR%\tipa\Payload' -DestinationPath '%OUTPUT_DIR%\%APP_NAME%.zip' -Force"
ren "%OUTPUT_DIR%\%APP_NAME%.zip" "%APP_NAME%.tipa"

REM 清理临时目录
rmdir /s /q "%OUTPUT_DIR%\tipa"

echo.
echo ============================================
echo   打包完成!
echo   %OUTPUT_DIR%\%APP_NAME%.tipa
echo ============================================
echo.
echo 安装方式:
echo   1. 将 TRApp.tipa 传输到 iPhone
echo   2. 在 TrollStore 中打开
echo   3. 点击 Install 安装
echo ============================================
pause