@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion

echo.
echo ===== 動画ファイル圧縮ツール =====
echo.
set /p input_path="圧縮対象のファイル/フォルダパスを入力してください: "

if "!input_path!"=="" (
    echo エラー: パスが入力されていません
    pause
    exit /b 1
)

if not exist "!input_path!" (
    echo エラー: 指定されたパス(!input_path!)が見つかりません
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0compress_videos.ps1" "!input_path!"
pause
