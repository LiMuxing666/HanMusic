[CmdletBinding()]
param(
    [string]$OutputDirectory = 'D:\dev\tmp\hanmusic-m5-audio',
    [string]$FfmpegPath = 'D:\dev\tools\audio-test\imageio_ffmpeg\binaries\ffmpeg-win-x86_64-v7.1.exe'
)

$ErrorActionPreference = 'Stop'
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not $outputRoot.StartsWith('D:\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'M5 generated audio and reports must be stored on D:.'
}
if (-not (Test-Path -LiteralPath $FfmpegPath -PathType Leaf)) {
    throw 'The existing ffmpeg executable was not found; pass -FfmpegPath explicitly.'
}
$fixtureDirectory = Join-Path $outputRoot '中文 空格'
New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
$wav = Join-Path $fixtureDirectory '测试 音频.wav'

function Invoke-FixtureFfmpeg {
    param([string[]]$Arguments)
    & $FfmpegPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg exited with code $LASTEXITCODE." }
}

# FFmpeg's sine source has amplitude 1/8. The filter reduces the generated
# sample to approximately 0.005 full scale before the probe's 0.02 volume.
# All files are synthesized; no user media or network download is involved.
Invoke-FixtureFfmpeg -Arguments @(
    '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=6',
    '-af', 'volume=0.04', '-ac', '1', '-c:a', 'pcm_s16le', $wav
)

$formats = @(
    @{ Extension = 'wav'; Codec = 'PCM signed 16-bit'; Container = 'RIFF/WAVE'; Options = @() },
    @{ Extension = 'mp3'; Codec = 'MP3'; Container = 'MP3'; Options = @('-c:a', 'libmp3lame', '-b:a', '128k') },
    @{ Extension = 'flac'; Codec = 'FLAC'; Container = 'FLAC'; Options = @('-c:a', 'flac', '-compression_level', '5') },
    @{ Extension = 'm4a'; Codec = 'AAC-LC'; Container = 'MPEG-4/M4A'; Options = @('-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart') },
    @{ Extension = 'ogg'; Codec = 'Vorbis'; Container = 'Ogg'; Options = @('-c:a', 'libvorbis', '-q:a', '4') },
    @{ Extension = 'aac'; Codec = 'AAC-LC'; Container = 'ADTS'; Options = @('-c:a', 'aac', '-b:a', '96k', '-f', 'adts') }
)
$fixtures = @()
foreach ($format in $formats) {
    $fileName = "测试 音频.$($format.Extension)"
    $target = Join-Path $fixtureDirectory $fileName
    if ($format.Extension -ne 'wav') {
        $arguments = @('-hide_banner', '-loglevel', 'error', '-nostdin', '-y', '-i', $wav,
            '-map', '0:a:0', '-map_metadata', '-1') + $format.Options + @($target)
        Invoke-FixtureFfmpeg -Arguments $arguments
    }
    # Decode each artifact to FFmpeg's null muxer before handing it to Flutter.
    Invoke-FixtureFfmpeg -Arguments @('-hide_banner', '-loglevel', 'error', '-nostdin',
        '-i', $target, '-map', '0:a:0', '-f', 'null', 'NUL')
    $file = Get-Item -LiteralPath $target
    $fixtures += [ordered]@{
        format = $format.Extension
        codec = $format.Codec
        container = $format.Container
        relativePath = "中文 空格/$fileName"
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        ffmpegDecodeVerified = $true
    }
}

$versions = [ordered]@{}
$packageName = $null
$wanted = @('just_audio', 'just_audio_media_kit', 'media_kit', 'media_kit_libs_windows_audio')
$lockPath = Join-Path $PSScriptRoot '../pubspec.lock'
foreach ($line in Get-Content -LiteralPath $lockPath) {
    if ($line -match '^  ([a-zA-Z0-9_]+):$') { $packageName = $Matches[1] }
    if (($packageName -in $wanted) -and ($line -match '^    version: "([^"]+)"$')) {
        $versions[$packageName] = $Matches[1]
    }
}
if ($versions.Count -ne $wanted.Count) { throw 'Could not read all audio backend versions from pubspec.lock.' }
$ffmpegVersion = (& $FfmpegPath -version | Select-Object -First 1)
$manifest = [ordered]@{
    schemaVersion = 1
    createdAt = [DateTime]::UtcNow.ToString('o')
    generator = 'tool/generate_m5_audio_fixtures.ps1'
    ffmpegVersion = $ffmpegVersion
    backendVersionsFromLockfile = $versions
    sampleRateHz = 48000
    channels = 1
    sourceDurationSeconds = 6
    sineFrequencyHz = 440
    approximatePeakFullScale = 0.005
    probeVolume = 0.02
    fixtures = $fixtures
    limitations = @('Generated-file coverage does not cover every codec profile, bit rate, damaged file or real-world tag.',
        'FFmpeg decode verification is separate from the actual Windows backend validation.')
}
$manifestPath = Join-Path $outputRoot 'fixtures.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8
Write-Output "Generated and decode-verified $($fixtures.Count) fixtures: $manifestPath"
