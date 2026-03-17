param([string]$InputPath)

# 設定値
$MIN_SIZE_FOR_COMPRESS = 100MB
$OUTPUT_FORMAT = "mp4"
$FFMPEG_CMD = "ffmpeg"
$FFPROBE_CMD = "ffprobe"
$CRF23_BITS_PER_PIXEL = 2.5      # CRF 23/medium preset時の推定bps/ピクセル（4K@30fps≒20Mbps、1080p@30fps≒5Mbps）
$DOWNSCALE_THRESHOLD_GB = 100    # 推定圧縮後サイズがこの値(GB)以上なら1920:1080にダウンスケール

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

# 推定圧縮後サイズをGBで算出
function Get-EstimatedSizeGB {
    param([int]$Width, [int]$Height, [double]$DurationSec, [double]$BitsPerPixel)
    return $DurationSec * $Width * $Height * $BitsPerPixel / 8 / 1GB
}

# バックアップを作成（ハードリンク優先、失敗時はコピー）
function Invoke-BackupFile {
    param([string]$SourcePath, [string]$BackupPath)
    try {
        New-Item -ItemType HardLink -Path $BackupPath -Target $SourcePath -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -Path $SourcePath -Destination $BackupPath -Force
    }
}

# 圧縮成功時：元ファイルを圧縮ファイルで置換
function Invoke-ReplaceWithCompressed {
    param([string]$InputFile, [string]$OutputFile, [string]$BackupFile)
    Remove-Item -Path $InputFile -Force -ErrorAction SilentlyContinue
    Rename-Item -Path $OutputFile -NewName $InputFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $BackupFile -ErrorAction SilentlyContinue
}

# 圧縮失敗時：バックアップから元ファイルを復元
function Invoke-RestoreFromBackup {
    param([string]$InputFile, [string]$OutputFile, [string]$BackupFile)
    Remove-Item -Path $OutputFile -Force -ErrorAction SilentlyContinue
    if (Test-Path $BackupFile) {
        Remove-Item -Path $InputFile -Force -ErrorAction SilentlyContinue
        Rename-Item -Path $BackupFile -NewName $InputFile -Force -ErrorAction SilentlyContinue
    }
}

# 動画情報取得スクリプトブロック（並列実行用）
$getVideoInfoScript = {
    param([string]$FilePath, [string]$FfprobeCmd, [double]$Crf23BitsPerPixel)
    $info = @{ Duration = 0; Width = 0; Height = 0 }
    $json = & $FfprobeCmd -v quiet -print_format json -show_streams -show_format "$FilePath" 2>$null
    if (-not $json) { return $info }
    $data = $json | ConvertFrom-Json
    # フォーマットから再生時間を取得（秒）
    if ($data.format.duration) {
        $info.Duration = [double]$data.format.duration
    }
    # 映像ストリームから解像度を取得
    $videoStream = $data.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    if ($videoStream) {
        $info.Width = [int]$videoStream.width
        $info.Height = [int]$videoStream.height
        if (-not $info.Duration -and $videoStream.duration) {
            $info.Duration = [double]$videoStream.duration
        }
    }
    $info.EstimatedSizeGB = Get-EstimatedSizeGB -Width $info.Width -Height $info.Height -DurationSec $info.Duration -BitsPerPixel $Crf23BitsPerPixel
    return $info
}

# 出力解像度を決定（推定圧縮後サイズがしきい値以上なら1920:1080にダウンスケール）
function Get-OutputResolution {
    param([object]$VideoInfo, [double]$ThresholdGB)
    if ($VideoInfo.EstimatedSizeGB -ge $ThresholdGB) {
        return "1920:1080"
    }
    return "$($VideoInfo.Width):$($VideoInfo.Height)"
}

# ランスペースに注入するヘルパー関数定義（[PowerShell]::Create() は親スコープを継承しないため）
$runspaceFunctions = [scriptblock]::Create(@"
function Get-EstimatedSizeGB { $( ${function:Get-EstimatedSizeGB} ) }
function Invoke-BackupFile { $( ${function:Invoke-BackupFile} ) }
function Invoke-ReplaceWithCompressed { $( ${function:Invoke-ReplaceWithCompressed} ) }
function Invoke-RestoreFromBackup { $( ${function:Invoke-RestoreFromBackup} ) }
function Get-OutputResolution { $( ${function:Get-OutputResolution} ) }
"@)

# 動画を圧縮（スクリプトブロック）
$compressionScript = {
    param([object]$Job)
    
    $FFMPEG_CMD = "ffmpeg"
    $InputFile = $Job.InputFile
    $OutputFile = $Job.OutputFile
    $VideoInfo = $Job.VideoInfo
    $BackupFile = $Job.BackupFile
    $DownscaleThresholdGB = $Job.DownscaleThresholdGB

    Invoke-BackupFile -SourcePath $InputFile -BackupPath $BackupFile

    $resolution = Get-OutputResolution -VideoInfo $VideoInfo -ThresholdGB $DownscaleThresholdGB

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
        Invoke-ReplaceWithCompressed -InputFile $InputFile -OutputFile $OutputFile -BackupFile $BackupFile
        return @{ Success = $true; File = (Split-Path $InputFile -Leaf); Error = "" }
    } else {
        Invoke-RestoreFromBackup -InputFile $InputFile -OutputFile $OutputFile -BackupFile $BackupFile
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
# フェーズ1: サイズチェックを先に実施
$sizeCheckedFiles = @()
foreach ($video in $videos) {
    $filePath = $video.FullName
    $fileSizeMB = Get-FileSizeInMB $filePath

    if ($fileSizeMB -le ($MIN_SIZE_FOR_COMPRESS / 1MB)) {
        Write-Log "スキップ: $(Split-Path $filePath -Leaf) ($('{0:F1}' -f $fileSizeMB) MB)" "WARN"
        $skipped++
        continue
    }
    $sizeCheckedFiles += @{ Path = $filePath; SizeMB = $fileSizeMB }
}

# フェーズ2: 動画情報を並列取得
$infoJobs = @()
foreach ($file in $sizeCheckedFiles) {
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript($runspaceFunctions).AddStatement().AddScript($getVideoInfoScript).AddArgument($file.Path).AddArgument($FFPROBE_CMD).AddArgument($CRF23_BITS_PER_PIXEL)
    $infoJobs += @{ Handle = $ps; AsyncResult = $ps.BeginInvoke(); Path = $file.Path; SizeMB = $file.SizeMB }
}

# フェーズ3: 情報取得完了次第キューに追加し、圧縮を並行して実行（パイプライン化）
$spinnerIndex = 0
while ($infoJobs.Count -gt 0 -or $jobQueue.Count -gt 0 -or $runningJobs.Count -gt 0) {
    # 完了した情報取得ジョブをキューに追加
    $completedInfoJobs = @()
    foreach ($infoJob in $infoJobs) {
        if ($infoJob.AsyncResult.IsCompleted) {
            $videoInfo = $infoJob.Handle.EndInvoke($infoJob.AsyncResult)[0]
            $infoJob.Handle.Dispose()

            $filePath = $infoJob.Path
            $fileSizeMB = $infoJob.SizeMB
            Write-Host ""  # スピナーをクリア
            Write-Log "キューに追加: $(Split-Path $filePath -Leaf) ($($videoInfo.Width)x$($videoInfo.Height), $('{0:F1}' -f $fileSizeMB) MB)"

            $tempFile = "$filePath.tmp.$OUTPUT_FORMAT"
            $backupFile = "$filePath.bak"

            $jobQueue += @{
                InputFile = $filePath
                OutputFile = $tempFile
                BackupFile = $backupFile
                VideoInfo = $videoInfo
                DownscaleThresholdGB = $DOWNSCALE_THRESHOLD_GB
            }
            $completedInfoJobs += $infoJob
        }
    }
    foreach ($infoJob in $completedInfoJobs) {
        $infoJobs = $infoJobs | Where-Object { $_ -ne $infoJob }
    }

    # 完了した圧縮ジョブを確認
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

        $ps = [PowerShell]::Create()
        $null = $ps.AddScript($runspaceFunctions).AddStatement().AddScript($compressionScript).AddArgument($jobItem)
        $asyncResult = $ps.BeginInvoke()

        $runningJobs += @{
            Handle = $ps
            AsyncResult = $asyncResult
        }
    }

    # 進捗表示とスピナー
    if ($infoJobs.Count -gt 0 -or $runningJobs.Count -gt 0 -or $jobQueue.Count -gt 0) {
        $activity = "情報取得中: $($infoJobs.Count)件, 実行中: $($runningJobs.Count)件, 待機中: $($jobQueue.Count)件"
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

