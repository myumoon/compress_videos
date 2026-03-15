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

# ログ出力関数
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
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
    $output = & $FFMPEG_CMD -v error -select_streams v:0 -show_entries stream=duration,width,height -of csv=p=0 "$FilePath" 2>&1 | Select-Object -First 1
    $info = @{
        Duration = 0
        Width = 0
        Height = 0
    }
    if ($output -match '(\d+\.?\d*),(\d+),(\d+)') {
        $info.Duration = [double]$matches[1]
        $info.Width = [int]$matches[2]
        $info.Height = [int]$matches[3]
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
    
    $resolution = $VideoInfo.Width -as [string] + ":$($VideoInfo.Height)"
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
    
    & $FFMPEG_CMD $command | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Remove-Item -Path $InputFile -Force -ErrorAction SilentlyContinue
        Rename-Item -Path $OutputFile -NewName $InputFile -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $BackupFile -ErrorAction SilentlyContinue
        return @{ Success = $true; File = (Split-Path $InputFile -Leaf) }
    } else {
        # 圧縮失敗時は元ファイルを復元
        Remove-Item -Path $OutputFile -Force -ErrorAction SilentlyContinue
        if (Test-Path $BackupFile) {
            Remove-Item -Path $InputFile -Force -ErrorAction SilentlyContinue
            Rename-Item -Path $BackupFile -NewName $InputFile -Force -ErrorAction SilentlyContinue
        }
        return @{ Success = $false; File = (Split-Path $InputFile -Leaf) }
    }
}

# 処理対象ファイルを取得
function Get-VideoFiles {
    param([string]$Path)
    $videos = @()

    if ((Get-Item $Path) -is [System.IO.FileInfo]) {
        if ($Path -match '\.(mp4|mov)$') {
            $videos += $Path
        }
    } else {
        $videos += Get-ChildItem -Path $Path -Recurse -Include @("*.mp4", "*.mov")
    }

    return $videos
}

# メイン処理
Write-Log "処理開始"
Write-Log "入力パス: $InputPath"

# ドライブタイプに応じて並列度を決定
$MAX_PARALLEL_JOBS = Get-OptimalParallelJobs $InputPath
Write-Log "並列ジョブ数: $MAX_PARALLEL_JOBS"

$videos = Get-VideoFiles $InputPath

if ($videos.Count -eq 0) {
    Write-Log "対象の動画ファイルが見つかりません" "WARN"
    exit 0
}

Write-Log "対象ファイル数: $($videos.Count)"

$jobQueue = @()
$processed = 0
$skipped = 0
$failed = 0
$runningJobs = @()
$startTime = Get-Date

# ジョブキューを作成
foreach ($video in $videos) {
    $filePath = $video.FullName
    $fileSizeMB = Get-FileSizeInMB $filePath

    if ($fileSizeMB -le 500) {
        Write-Log "スキップ: $(Split-Path $filePath -Leaf) ($('{0:F1}' -f $fileSizeMB) MB)" "WARN"
        $skipped++
        continue
    }

    $videoInfo = Get-VideoInfo $filePath
    Write-Log "キューに追加: $(Split-Path $filePath -Leaf) ($($videoInfo.Width)x$($videoInfo.Height), $('{0:F1}' -f $fileSizeMB) MB)"

    $tempFile = "$filePath.tmp.$OUTPUT_FORMAT"
    $backupFile = "$filePath.bak"

    $jobQueue += @{
        InputFile = $filePath
        OutputFile = $tempFile
        BackupFile = $backupFile
        VideoInfo = $videoInfo
    }
}

# ジョブを実行
while ($jobQueue.Count -gt 0 -or $runningJobs.Count -gt 0) {
    # 完了したジョブを確認
    $completedJobs = @()
    foreach ($job in $runningJobs) {
        if ($job.Handle.IsCompleted) {
            $result = $job.Handle.EndInvoke($job.AsyncResult)
            if ($result.Success) {
                Write-Log "圧縮完了: $($result.File)" "SUCCESS"
                $processed++
            } else {
                Write-Log "圧縮失敗: $($result.File)" "ERROR"
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
        $jobQueue = $jobQueue[1..($jobQueue.Count - 1)]

        Write-Log "圧縮開始: $(Split-Path $jobItem.InputFile -Leaf)"

        $ps = [PowerShell]::Create().AddScript($compressionScript).AddArgument($jobItem)
        $asyncResult = $ps.BeginInvoke()

        $runningJobs += @{
            Handle = $ps
            AsyncResult = $asyncResult
        }
    }

    if ($runningJobs.Count -gt 0) {
        Start-Sleep -Milliseconds 500
    }
}

Write-Log "処理完了: 圧縮$processed件、スキップ$skipped件、失敗$failed件"

$endTime = Get-Date
$totalTime = $endTime - $startTime
Write-Log "総処理時間: $($totalTime.Hours)時間 $($totalTime.Minutes)分 $($totalTime.Seconds)秒"

