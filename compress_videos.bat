@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion

echo.
echo ===== 動画ファイル圧縮ツール =====
echo.

REM コマンドライン引数がある場合（D&D）
if not "%~1"=="" (
    echo D&D検出: 複数のファイル/フォルダを処理します
    echo.
    
    REM 全引数をセミコロンで結合
    set input_path=
    for %%A in (%*) do (
        if defined input_path (
            set "input_path=!input_path!;%%~A"
        ) else (
            set "input_path=%%~A"
        )
    )
    
    goto :execute
)

REM コマンドライン引数がない場合（直接実行）
echo 複数のパスを入力する場合はセミコロン(;)またはカンマ(,)で区切ってください
echo 例: C:\Videos;D:\Footage\project1
echo.
set /p input_path="圧縮対象のファイル/フォルダパスを入力してください: "

if "!input_path!"=="" (
    echo エラー: パスが入力されていません
    pause
    exit /b 1
)

:execute
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0compress_videos.ps1" "!input_path!"
if errorlevel 1 (
    echo エラー: 圧縮処理中に問題が発生しました
    pause
)
