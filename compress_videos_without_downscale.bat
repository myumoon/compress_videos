@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion

echo.
echo ===== 動画ファイル圧縮ツール（ダウンスケールなし・CRF23） =====
echo.

set "PS1_ARGS=-MinSizeMB 500 -Crf 23"
call "%~dp0_compress_base.bat" %*
