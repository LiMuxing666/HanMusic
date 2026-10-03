param([string]$ScratchDirectory = (Join-Path $env:TEMP 'hanmusic-notice-tests'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'windows_third_party_notices.ps1')
$scratch = [IO.Path]::GetFullPath($ScratchDirectory)
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$runRoot = Join-Path $scratch ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$names = @('README.md','mpv-Copyright.txt','LGPL-2.1.txt','FFmpeg-LICENSE-n6.0.md',
    'LGPL-3.0.txt','GPL-3.0.txt','hls.js-1.4.10-LICENSE.txt','Apache-2.0.txt','JNI-AOSP-ATTRIBUTION.txt')
$flutterText = [char]0xfeff + 'Flutter original ' + [char]0x4e2d + "`r`nsecond line`n"

function New-NoticeFixture {
    param([string]$Name, [bool]$Reverse = $false)
    $root = Join-Path $runRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $root 'data\flutter_assets'),(Join-Path $root 'licenses') -Force | Out-Null
    $stream = [IO.File]::Create((Join-Path $root 'data\flutter_assets\NOTICES.Z'))
    $gzip = New-Object IO.Compression.GZipStream($stream, [IO.Compression.CompressionMode]::Compress)
    try { $bytes=$utf8.GetBytes($flutterText); $gzip.Write($bytes, 0, $bytes.Length) }
    finally { $gzip.Dispose(); $stream.Dispose() }
    $fixtureNames = @($names) + 'additional-notice.txt'
    if ($Reverse) { [Array]::Reverse($fixtureNames) }
    foreach ($name in $fixtureNames) {
        $content = $name + ' ' + [char]0x6587 + "`r`noriginal ending"
        if ($name -eq 'additional-notice.txt') { $content = [char]0xfeff + $content }
        [IO.File]::WriteAllText((Join-Path $root "licenses\$name"), $content, $utf8)
    }
    foreach ($name in @('flutter_windows.dll','libmpv-2.dll','media_kit_libs_windows_audio_plugin.dll','dartjni.dll')) {
        [IO.File]::WriteAllText((Join-Path $root $name), "fixture-$name", $utf8)
    }
    return $root
}

function Assert-NoticeReject {
    param([string]$Root, [string]$Expected = '')
    $rejected = $false
    try { Write-HanMusicThirdPartyNotices -PackageDirectory $Root | Out-Null }
    catch {
        if ($Expected -and $_.Exception.Message -notlike "*$Expected*") { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Invalid notice input was accepted.' }
    if (Test-Path -LiteralPath (Join-Path $Root 'THIRD_PARTY_NOTICES.txt')) { throw 'Rejected inputs created an output.' }
}

$first = New-NoticeFixture 'first'
$summary = Write-HanMusicThirdPartyNotices -PackageDirectory $first
$combinedPath = Join-Path $first $summary.path
$combined = [IO.File]::ReadAllText($combinedPath, $utf8)
if (-not $combined.Contains($flutterText) -or $summary.supplementalFileCount -ne 10 -or $summary.nativeComponentCount -ne 4) {
    throw 'Flutter bytes, supplemental materials or native mapping were lost.'
}
foreach ($name in (@($names) + 'additional-notice.txt')) {
    $source = Join-Path $first "licenses\$name"
    $content = $utf8.GetString([IO.File]::ReadAllBytes($source))
    $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $combined.Contains($content) -or -not $combined.Contains("Source SHA-256: $hash")) { throw "Missing original material or hash: $name" }
}
foreach ($name in @('flutter_windows.dll','libmpv-2.dll','media_kit_libs_windows_audio_plugin.dll','dartjni.dll')) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $first $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $combined.Contains("$name`nSHA-256: $hash")) { throw "Native component fingerprint was lost: $name" }
}
if (-not $combined.Contains('corresponding sources') -or -not $combined.Contains('does not grant a HanMusic project license')) {
    throw 'Unresolved release conditions were lost.'
}
$second = New-NoticeFixture 'second' -Reverse $true
$null = Write-HanMusicThirdPartyNotices -PackageDirectory $second
if ((Get-FileHash -LiteralPath $combinedPath).Hash -ne (Get-FileHash -LiteralPath (Join-Path $second $summary.path)).Hash) {
    throw 'Combined notices depend on creation order or absolute paths.'
}

$missing = New-NoticeFixture 'missing-license'
Remove-Item -LiteralPath (Join-Path $missing 'licenses\LGPL-3.0.txt')
Assert-NoticeReject $missing 'Missing required notice material'
$invalid = New-NoticeFixture 'invalid-gzip'
[IO.File]::WriteAllText((Join-Path $invalid 'data\flutter_assets\NOTICES.Z'), 'not gzip', $utf8)
Assert-NoticeReject $invalid
$empty = New-NoticeFixture 'empty-flutter'
$stream = [IO.File]::Create((Join-Path $empty 'data\flutter_assets\NOTICES.Z'))
$gzip = New-Object IO.Compression.GZipStream($stream, [IO.Compression.CompressionMode]::Compress)
$gzip.Dispose(); $stream.Dispose()
Assert-NoticeReject $empty 'Flutter notices are empty'
$badUtf8 = New-NoticeFixture 'bad-utf8'
[IO.File]::WriteAllBytes((Join-Path $badUtf8 'licenses\README.md'), [byte[]]@(0xff, 0xff))
Assert-NoticeReject $badUtf8
$missingNative = New-NoticeFixture 'missing-native'
Remove-Item -LiteralPath (Join-Path $missingNative 'libmpv-2.dll')
Assert-NoticeReject $missingNative 'Missing packaged native component'
$existingHash = (Get-FileHash -LiteralPath $combinedPath).Hash
$rejected = $false
try { Write-HanMusicThirdPartyNotices -PackageDirectory $first | Out-Null }
catch { if ($_.Exception.Message -notlike '*output already exists*') { throw }; $rejected=$true }
if (-not $rejected -or (Get-FileHash -LiteralPath $combinedPath).Hash -ne $existingHash) { throw 'Existing combined notices changed.' }
$linked = New-NoticeFixture 'linked-license-tree'
$external = Join-Path $runRoot 'external-materials'
New-Item -ItemType Directory -Path $external | Out-Null
New-Item -ItemType Junction -Path (Join-Path $linked 'licenses\linked') -Target $external | Out-Null
Assert-NoticeReject $linked 'reparse point'
Write-Output '9 third-party notice checks passed; originals, deterministic order and failure boundaries preserved.'
Write-Output ("Evidence: $runRoot")
