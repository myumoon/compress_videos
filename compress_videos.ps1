param([string]$InputPath)

# 設定値
$MIN_SIZE_FOR_COMPRESS = 500MB
$OUTPUT_FORMAT = "mp4"
$FFMPEG_CMD = "ffmpeg"

# ドライブタイプを判定して並列度を決定
function Get-OptimalParallelJobs {
    param([string]$FilePath)
    
    $drive = (Get-Item $FilePath).PSDrive.Name
    $driveInfo = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($drive):'"
    
    # ドライブタイプ: 2=フロッピーディスク, 3=HDD, 4=リムーバブルメディア, 5=CD-ROM
    $driveType = $driveInfo.DriveType
    $cpuCores = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
    
    if ($driveType -eq 3) {
        # HDD: 並列度を1～2に制限
        Write-Log "HDD検出: 並列度を制限します"
        return [Math]::Max(1, [Math]::Min(2, $cpuCores - 1))
    } else {
        # SSD: 通常通りコア数-1で処理
        return [Math]::Max(1, $cpuCores - 1)
    }
}

$MAX_PARALLEL_JOBS = 0  # 後で設定される

# グローバル変数：スピナー状態
$spinnerIndex = 0
$spinnerChars = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
$runningJobs = @()  # グローバル変数化して割り込みハンドラーからアクセス可能に

# クリーンアップ関数
function Cleanup-Jobs {
    Write-Host ""
    Write-Log "キャンセル中..." "WARN"
    
    foreach ($job in $runningJobs) {
        try {
            $job.Handle.Stop()
            $job.Handle.Dispose()
        } catch {
            # スルー
        }
    }
    
    # ffmpegプロセスを全て強制終了
    try {
        Get-Process ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Log "ffmpegプロセスを終了しました" "INFO"
    } catch {
        # スルー
    }
    
    Write-Log "キャンセルしました" "WARN"
    exit 1
}

# Ctrl+C割り込みハンドラーを登録
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Cleanup-Jobs }

# ログ出力関数
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

# スピナー表示関数
function Show-Spinner {
    param([string]$Message, [int]$Index)
    $spinner = $spinnerChars[$Index % $spinnerChars.Count]
    Write-Host "`r$spinner $Message" -NoNewline -ForegroundColor Cyan
}

# 進捗表示関数
function Show-Progress {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Activity
    )
    if ($Total -eq 0) { return }
    
    $percentage = [math]::Round(($Current / $Total) * 100)
    $barLength = 20
    $filledLength = [math]::Round(($Current / $Total) * $barLength)
    $bar = ('█' * $filledLength) + ('░' * ($barLength - $filledLength))
    
    Write-Host "`r[$bar] $percentage% ($Current/$Total) - $Activity" -NoNewline -ForegroundColor Green
}

# ファイルサイズを取得
function Get-FileSizeInMB {
    param([string]$FilePath)
    $file = Get-Item $FilePath -ErrorAction SilentlyContinue
    if ($file) {
        return $file.Length / 1MB
    }
    return 0
}

# 動画情報を取得
function Get-VideoInfo {
    param([string]$FilePath)
    $output = & $FFMPEG_CMD -i "$FilePath" 2>&1
    $info = @{
        Duration = 0
        Width = 0
        Height = 0
    }
    # Duration: 00:05:30.12 の形式から秒数を取得
    $durationLine = $output | Select-String 'Duration:\s*(\d+):(\d+):(\d+)\.(\d+)'
    if ($durationLine) {
        $m = $durationLine.Matches[0].Groups
        $info.Duration = [int]$m[1].Value * 3600 + [int]$m[2].Value * 60 + [int]$m[3].Value + [double]"0.$($m[4].Value)"
    }
    # Video: ... 1920x1080 の形式から解像度を取得
    $videoLine = $output | Select-String 'Stream.*Video.*\s(\d{2,5})x(\d{2,5})'
    if ($videoLine) {
        $m = $videoLine.Matches[0].Groups
        $info.Width = [int]$m[1].Value
        $info.Height = [int]$m[2].Value
    }
    return $info
}

# 出力解像度を決定
function Get-OutputResolution {
    param([object]$VideoInfo)
    $duration = $VideoInfo.Duration / 60
    $is4k = ($VideoInfo.Width -ge 3840 -or $VideoInfo.Height -ge 2160)

    if ($duration -ge 10 -and $is4k) {
        return "1920:1080"
    }
    return "$($VideoInfo.Width):$($VideoInfo.Height)"
}

# 動画を圧縮（スクリプトブロック）
$compressionScript = {
    param([object]$Job)
    
    $FFMPEG_CMD = "ffmpeg"
    $InputFile = $Job.InputFile
    $OutputFile = $Job.OutputFile
    $VideoInfo = $Job.VideoInfo
    $BackupFile = $Job.BackupFile
    
    $resolution = "$($VideoInfo.Width):$($VideoInfo.Height)"
    if ($VideoInfo.Duration / 60 -ge 10 -and ($VideoInfo.Width -ge 3840 -or $VideoInfo.Height -ge 2160)) {
        $resolution = "1920:1080"
    }
    
    # CRF値は品質とファイルサイズのバランスを調整するためのもので23は一般的なデフォルト値
    $crf = 23

    $command = @(
        "-i", $InputFile,
        "-c:v", "libx264",
        "-preset", "medium",
        "-crf", $crf,
        "-vf", "scale=$resolution",
        "-c:a", "aac",
        "-b:a", "128k",
        "-y",
        $OutputFile
    )
    
    $errorOutput = & $FFMPEG_CMD $command 2>&1

    if ($LASTEXITCODE -eq 0) {
        Remove-Item -Path $InputFile -Force -ErrorAction SilentlyContinue
        Rename-Item -Path $OutputFile -NewName $InputFile -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $BackupFile -ErrorAction SilentlyContinue
        return @{ Success = $true; File = (Split-Path $InputFile -Leaf); Error = "" }
    } else {
        # 圧縮失敗時は元ファイルを復元
        Remove-Item -Path $OutputFile -Force -ErrorAction SilentlyContinue
        if (Test-Path $BackupFile) {
            Remove-Item -Path $InputFile -Force -ErrorAction SilentlyContinue
            Rename-Item -Path $BackupFile -NewName $InputFile -Force -ErrorAction SilentlyContinue
        }
        $errMsg = ($errorOutput | Out-String).Trim()
        return @{ Success = $false; File = (Split-Path $InputFile -Leaf); Error = $errMsg }
    }
}

# 処理対象ファイルを取得
function Get-VideoFiles {
    param([string]$Path)
    $videos = @()

    if ((Get-Item $Path) -is [System.IO.FileInfo]) {
        if ($Path -match '\.(mp4|mov)$') {
            $videos += Get-Item $Path
        }
    } else {
        $videos += Get-ChildItem -Path $Path -Recurse -Include @("*.mp4", "*.mov")
    }

    return $videos
}

# メイン処理
Write-Log "処理開始"

# 入力パスを複数対応に解析
if ([string]::IsNullOrWhiteSpace($InputPath)) {
    Write-Log "エラー: パスが入力されていません" "ERROR"
    exit 1
}

$inputPaths = @()
if ($InputPath -match '^".*"$|^''.*''$') {
    # クォーテーション囲みを削除
    $InputPath = $InputPath -replace '^["'']|["'']$', ''
}

# セミコロンまたはカンマで複数パスを分割
if ($InputPath.Contains(';') -or $InputPath.Contains(',')) {
    $inputPaths = $InputPath -split '[;,]' | ForEach-Object { $_.Trim() }
} else {
    $inputPaths = @($InputPath)
}

Write-Log "入力パス数: $($inputPaths.Count)"
foreach ($path in $inputPaths) {
    Write-Log "  - $path"
}

# ドライブタイプに応じて並列度を決定（最初のパスから判定）
$MAX_PARALLEL_JOBS = Get-OptimalParallelJobs $inputPaths[0]
Write-Log "並列ジョブ数: $MAX_PARALLEL_JOBS"

# 全ての入力パスから動画ファイルを集約
$videos = @()
foreach ($path in $inputPaths) {
    if (-not (Test-Path $path)) {
        Write-Log "警告: パスが見つかりません: $path" "WARN"
        continue
    }
    $videos += Get-VideoFiles $path
}

if ($videos.Count -eq 0) {
    Write-Log "対象の動画ファイルが見つかりません" "WARN"
    exit 0
}

Write-Log "対象ファイル数: $($videos.Count)"

$jobQueue = @()
$processed = 0
$skipped = 0
$failed = 0
$startTime = Get-Date

# ジョブキューを作成
foreach ($video in $videos) {
    $filePath = $video.FullName
    $fileSizeMB = Get-FileSizeInMB $filePath

    if ($fileSizeMB -le ($MIN_SIZE_FOR_COMPRESS / 1MB)) {
        Write-Log "スキップ: $(Split-Path $filePath -Leaf) ($('{0:F1}' -f $fileSizeMB) MB)" "WARN"
        $skipped++
        continue
    }

    $videoInfo = Get-VideoInfo $filePath
    Write-Log "キューに追加: $(Split-Path $filePath -Leaf) ($($videoInfo.Width)x$($videoInfo.Height), $('{0:F1}' -f $fileSizeMB) MB)"

    $tempFile = "$filePath.tmp.$OUTPUT_FORMAT"
    $backupFile = "$filePath.bak"

    # バックアップを作成（ハードリンク優先、失敗時はコピー）
    try {
        New-Item -ItemType HardLink -Path $backupFile -Target $filePath -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -Path $filePath -Destination $backupFile -Force
    }

    $jobQueue += @{
        InputFile = $filePath
        OutputFile = $tempFile
        BackupFile = $backupFile
        VideoInfo = $videoInfo
    }
}

# ジョブを実行
$spinnerIndex = 0
while ($jobQueue.Count -gt 0 -or $runningJobs.Count -gt 0) {
    # 完了したジョブを確認
    $completedJobs = @()
    foreach ($job in $runningJobs) {
        if ($job.AsyncResult.IsCompleted) {
            $result = $job.Handle.EndInvoke($job.AsyncResult)
            if ($result.Success) {
                Write-Host ""  # スピナーをクリア
                Write-Log "圧縮完了: $($result.File)" "SUCCESS"
                $processed++
            } else {
                Write-Host ""  # スピナーをクリア
                Write-Log "圧縮失敗: $($result.File)`n$($result.Error)" "ERROR"
                $failed++
            }
            $completedJobs += $job
        }
    }

    # 完了したジョブを削除
    foreach ($job in $completedJobs) {
        $runningJobs = $runningJobs | Where-Object { $_ -ne $job }
    }

    # 新しいジョブを開始
    while ($runningJobs.Count -lt $MAX_PARALLEL_JOBS -and $jobQueue.Count -gt 0) {
        $jobItem = $jobQueue[0]
        if ($jobQueue.Count -le 1) {
            $jobQueue = @()
        } else {
            $jobQueue = $jobQueue[1..($jobQueue.Count - 1)]
        }

        Write-Host ""  # スピナーをクリア
        Write-Log "圧縮開始: $(Split-Path $jobItem.InputFile -Leaf)"

        $ps = [PowerShell]::Create().AddScript($compressionScript).AddArgument($jobItem)
        $asyncResult = $ps.BeginInvoke()

        $runningJobs += @{
            Handle = $ps
            AsyncResult = $asyncResult
        }
    }

    # 進捗表示とスピナー
    if ($runningJobs.Count -gt 0 -or $jobQueue.Count -gt 0) {
        $totalProcessed = $processed + $failed + $runningJobs.Count + $jobQueue.Count
        $currentProcessing = $processed + $failed
        $activity = "実行中: $($runningJobs.Count)件, 待機中: $($jobQueue.Count)件"
        
        Show-Spinner "処理中... $activity" $spinnerIndex
        $spinnerIndex++
        
        Start-Sleep -Milliseconds 500
    }
}

Write-Host ""  # スピナーをクリア

Write-Log "処理完了: 圧縮$processed件、スキップ$skipped件、失敗$failed件"

$endTime = Get-Date
$totalTime = $endTime - $startTime
Write-Log "総処理時間: $($totalTime.Hours)時間 $($totalTime.Minutes)分 $($totalTime.Seconds)秒"

