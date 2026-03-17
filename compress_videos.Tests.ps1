#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    # メイン処理より前の関数・定数定義のみを読み込む
    $content  = Get-Content "$PSScriptRoot/compress_videos.ps1" -Raw
    $defsOnly = ($content -split '(?m)^# メイン処理')[0]
    . ([scriptblock]::Create($defsOnly))
}

# -------------------------------------------------------------------------
Describe "設定値の妥当性" {
    It "スキップしきい値は 500MB である" {
        $MIN_SIZE_FOR_COMPRESS | Should -Be 500MB
    }
    It "ダウンスケールしきい値は 10GB である" {
        $DOWNSCALE_THRESHOLD_GB | Should -Be 10
    }
    It "CRF23 の推定 bps/ピクセルは正の値である" {
        $CRF23_BITS_PER_PIXEL | Should -BeGreaterThan 0
    }
}

# -------------------------------------------------------------------------
Describe "Get-FileSizeInMB" {
    BeforeAll { $dir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "pester_$(Get-Random)") }
    AfterAll  { Remove-Item $dir.FullName -Recurse -Force -EA SilentlyContinue }

    It "ファイルのバイト数を MB に変換して返す" {
        $file = New-Item -ItemType File -Path (Join-Path $dir.FullName "2mb.dat")
        [IO.File]::WriteAllBytes($file.FullName, [byte[]]::new(2 * 1MB))

        Get-FileSizeInMB $file.FullName | Should -BeExactly 2.0
    }

    It "存在しないファイルは 0 を返す" {
        Get-FileSizeInMB (Join-Path $dir.FullName "ghost.mp4") | Should -Be 0
    }
}

# -------------------------------------------------------------------------
Describe "Get-VideoFiles" {
    BeforeAll {
        $dir    = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "pester_$(Get-Random)")
        $subDir = New-Item -ItemType Directory -Path (Join-Path $dir.FullName "sub")

        New-Item -ItemType File -Path (Join-Path $dir.FullName    "a.mp4") | Out-Null
        New-Item -ItemType File -Path (Join-Path $dir.FullName    "b.mov") | Out-Null
        New-Item -ItemType File -Path (Join-Path $dir.FullName    "c.txt") | Out-Null
        New-Item -ItemType File -Path (Join-Path $subDir.FullName "d.mp4") | Out-Null
    }
    AfterAll { Remove-Item $dir.FullName -Recurse -Force -EA SilentlyContinue }

    It "mp4 を検出する" {
        (Get-VideoFiles $dir.FullName).Name | Should -Contain "a.mp4"
    }
    It "mov を検出する" {
        (Get-VideoFiles $dir.FullName).Name | Should -Contain "b.mov"
    }
    It "サブフォルダも再帰的に検索する" {
        (Get-VideoFiles $dir.FullName).Name | Should -Contain "d.mp4"
    }
    It "mp4・mov 以外は除外する" {
        (Get-VideoFiles $dir.FullName).Name | Should -Not -Contain "c.txt"
    }

    Context "ファイルを直接指定した場合" {
        It "指定した動画ファイル 1 件のみ返す" {
            @(Get-VideoFiles (Join-Path $dir.FullName "a.mp4")).Count | Should -Be 1
        }
        It "非動画ファイルを指定すると空を返す" {
            @(Get-VideoFiles (Join-Path $dir.FullName "c.txt")).Count | Should -Be 0
        }
    }
}

# -------------------------------------------------------------------------
Describe "Get-EstimatedSizeGB" {
    It "4K・1 時間の推定サイズは 10GB 未満である" {
        Get-EstimatedSizeGB -Width 3840 -Height 2160 -DurationSec (60 * 60) -BitsPerPixel $CRF23_BITS_PER_PIXEL |
            Should -BeLessThan $DOWNSCALE_THRESHOLD_GB
    }
    It "4K・70 分の推定サイズは 10GB を超える" {
        Get-EstimatedSizeGB -Width 3840 -Height 2160 -DurationSec (70 * 60) -BitsPerPixel $CRF23_BITS_PER_PIXEL |
            Should -BeGreaterThan $DOWNSCALE_THRESHOLD_GB
    }
    It "1080p は同じ時間の 4K より推定サイズが小さい" {
        $fhd = Get-EstimatedSizeGB -Width 1920 -Height 1080 -DurationSec (60 * 60) -BitsPerPixel $CRF23_BITS_PER_PIXEL
        $uhd = Get-EstimatedSizeGB -Width 3840 -Height 2160 -DurationSec (60 * 60) -BitsPerPixel $CRF23_BITS_PER_PIXEL
        $fhd | Should -BeLessThan $uhd
    }
}

# -------------------------------------------------------------------------
Describe "Get-OutputResolution（ダウンスケール判定）" {
    It "推定サイズがしきい値以上なら 1920:1080 にダウンスケールする" {
        $info = @{ Width = 3840; Height = 2160; EstimatedSizeGB = 12.0 }
        Get-OutputResolution $info $DOWNSCALE_THRESHOLD_GB | Should -Be "1920:1080"
    }
    It "推定サイズがしきい値ちょうどでもダウンスケールする" {
        $info = @{ Width = 3840; Height = 2160; EstimatedSizeGB = 10.0 }
        Get-OutputResolution $info $DOWNSCALE_THRESHOLD_GB | Should -Be "1920:1080"
    }
    It "推定サイズがしきい値未満なら元の解像度を維持する" {
        $info = @{ Width = 3840; Height = 2160; EstimatedSizeGB = 8.0 }
        Get-OutputResolution $info $DOWNSCALE_THRESHOLD_GB | Should -Be "3840:2160"
    }
    It "4K 以外でも推定サイズがしきい値以上であればダウンスケールする" {
        $info = @{ Width = 2560; Height = 1440; EstimatedSizeGB = 11.0 }
        Get-OutputResolution $info $DOWNSCALE_THRESHOLD_GB | Should -Be "1920:1080"
    }
}

# -------------------------------------------------------------------------
Describe "バックアップ作成" {
    BeforeAll { $dir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "pester_$(Get-Random)") }
    AfterAll  { Remove-Item $dir.FullName -Recurse -Force -EA SilentlyContinue }

    It "バックアップ後も元ファイルが存在する" {
        $src = New-Item -ItemType File -Path (Join-Path $dir.FullName "src1.mp4")
        $bak = Join-Path $dir.FullName "src1.mp4.bak"

        Invoke-BackupFile -SourcePath $src.FullName -BackupPath $bak

        Test-Path $src.FullName | Should -Be $true
    }
    It "バックアップは元ファイルと同一内容を持つ" {
        $src = New-Item -ItemType File -Path (Join-Path $dir.FullName "src2.mp4")
        [IO.File]::WriteAllText($src.FullName, "important data")
        $bak = Join-Path $dir.FullName "src2.mp4.bak"

        Invoke-BackupFile -SourcePath $src.FullName -BackupPath $bak

        Get-Content $bak | Should -Be "important data"
    }
    It "ハードリンクの場合、元ファイルを削除してもバックアップの内容は保持される" {
        $src = New-Item -ItemType File -Path (Join-Path $dir.FullName "src3.mp4")
        [IO.File]::WriteAllText($src.FullName, "must not lose")
        $bak = Join-Path $dir.FullName "src3.mp4.bak"

        Invoke-BackupFile -SourcePath $src.FullName -BackupPath $bak
        Remove-Item $src.FullName -Force

        Test-Path $bak   | Should -Be $true
        Get-Content $bak | Should -Be "must not lose"
    }
}

# -------------------------------------------------------------------------
Describe "圧縮成功時のファイル置換" {
    BeforeAll { $dir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "pester_$(Get-Random)") }
    AfterAll  { Remove-Item $dir.FullName -Recurse -Force -EA SilentlyContinue }

    BeforeEach {
        $script:src = Join-Path $dir.FullName "video.mp4"
        $script:tmp = Join-Path $dir.FullName "video.mp4.tmp.mp4"
        $script:bak = Join-Path $dir.FullName "video.mp4.bak"
        [IO.File]::WriteAllText($script:src, "original")
        [IO.File]::WriteAllText($script:tmp, "compressed")
        [IO.File]::WriteAllText($script:bak, "original")

        Invoke-ReplaceWithCompressed -InputFile $script:src -OutputFile $script:tmp -BackupFile $script:bak
    }

    It "元ファイルが圧縮済み内容に置き換わる" {
        Get-Content $script:src | Should -Be "compressed"
    }
    It "一時ファイルが削除される" {
        Test-Path $script:tmp | Should -Be $false
    }
    It "バックアップが削除される" {
        Test-Path $script:bak | Should -Be $false
    }
}

# -------------------------------------------------------------------------
Describe "圧縮失敗時の元ファイル復元" {
    BeforeAll { $dir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "pester_$(Get-Random)") }
    AfterAll  { Remove-Item $dir.FullName -Recurse -Force -EA SilentlyContinue }

    BeforeEach {
        $script:src = Join-Path $dir.FullName "video.mp4"
        $script:tmp = Join-Path $dir.FullName "video.mp4.tmp.mp4"
        $script:bak = Join-Path $dir.FullName "video.mp4.bak"
        [IO.File]::WriteAllText($script:src, "original")
        [IO.File]::WriteAllText($script:tmp, "broken_partial")
        [IO.File]::WriteAllText($script:bak, "original")

        Invoke-RestoreFromBackup -InputFile $script:src -OutputFile $script:tmp -BackupFile $script:bak
    }

    It "バックアップから元ファイルが復元される" {
        Get-Content $script:src | Should -Be "original"
    }
    It "一時ファイルが削除される" {
        Test-Path $script:tmp | Should -Be $false
    }
}
