@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion

echo.
echo ===== 動画ファイル圧縮ツール（FHDダウンスケールあり・20GB基準・CRF23） =====
echo.

set "PS1_ARGS=-DownscaleThresholdGB 20 -MinSizeMB 500 -Crf 23"
call "%~dp0_compress_base.bat" %*
