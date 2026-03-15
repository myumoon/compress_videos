# CLAUDE.md

このファイルはこのリポジトリのコードで作業するときのClaude Codeのための情報を提供します。

## Overview

- @README.mdを参照

## Usage

```
compress_videos.bat [path1] [path2] ...
```

Or run directly and enter paths interactively. Multiple paths can be separated by `;` or `,`.

The `.bat` file is the entry point — it collects arguments, joins them with `;`, then delegates to the PowerShell script:

```
powershell -NoProfile -ExecutionPolicy Bypass -File compress_videos.ps1 "path1;path2"
```

## Architecture

- **`compress_videos.bat`** — Entry point. Handles D&D (drag-and-drop) and manual path input. Joins multiple arguments with `;` and passes them to the PowerShell script.
- **`compress_videos.ps1`** — Core logic. Parses input paths, discovers video files, and runs FFmpeg in parallel background jobs.

## Key Behavior

- **Skip threshold**: Files ≤ 500 MB are skipped without compression.
- **Parallelism**: Determined at runtime based on drive type — HDD gets 1–2 parallel jobs; SSD gets `(CPU cores - 1)` jobs.
- **4K downscale**: Videos ≥ 3840×2160 that are ≥ 10 minutes long are scaled down to 1920×1080.
- **FFmpeg settings**: `libx264`, `preset medium`, `CRF 23`, audio `aac 128k`.
- **File replacement**: On success, the original file is replaced in-place (original deleted, `.tmp.mp4` renamed to original name). On failure, the original is restored from `.bak`.
- **Cancellation**: Ctrl+C triggers a cleanup handler that stops all PowerShell jobs and force-kills any running `ffmpeg` processes.

## Dependencies

- **FFmpeg** must be available on `PATH` as `ffmpeg`.
- Windows PowerShell (uses `Win32_LogicalDisk` and `Win32_Processor` WMI classes).

## 注意点

- 単一責任の原則に基づく簡潔なコード
- 回答、ソースコメントは全て日本語

## 禁止事項

- ユーザーの指示とは関係のないコードやコメントの修正
