# テストファイルをUTF-8 BOMで保存し直してからPesterを実行
$testFile = "$PSScriptRoot/compress_videos.Tests.ps1"
$utf8bom = New-Object Text.UTF8Encoding $true
$content = [IO.File]::ReadAllText($testFile, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($testFile, $content, $utf8bom)

Import-Module Pester -MinimumVersion 5.0
Invoke-Pester $testFile -Output Detailed
