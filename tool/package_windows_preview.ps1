[CmdletBinding()]
param(
    [string]$ProjectDirectory = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputRoot = 'D:\dev\releases\HanMusic',
    [string]$PackageName = ('HanMusic-Windows-x64-M5-preview-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'windows_packaging_utils.ps1')

if ($PackageName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]+$') {
    throw 'PackageName must be a plain file name, not a path.'
}
$project = (Resolve-Path -LiteralPath $ProjectDirectory).Path
if ($project -match '[^\x00-\x7F]') {
    throw 'Use the ASCII project junction for Flutter Windows builds.'
}
$output = [IO.Path]::GetFullPath($OutputRoot)
$stage = Join-Path $output $PackageName
$archive = "$stage.zip"
if ((Test-Path -LiteralPath $stage) -or (Test-Path -LiteralPath $archive)) {
    throw 'Output already exists; choose a new PackageName. Existing packages are never overwritten.'
}
$release = [IO.Path]::GetFullPath((Join-Path $project 'build\windows\x64\runner\Release'))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $project 'build')) + [IO.Path]::DirectorySeparatorChar
if (-not $release.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Release path is outside the project build directory.'
}
Assert-HanMusicBuildPath -Project $project -Release $release
$physicalBuildRoot = (Get-HanMusicPhysicalPath (Join-Path $project 'build')).TrimEnd('\')
$physicalOutput = Get-HanMusicPhysicalPath $output
if ($physicalOutput -eq $physicalBuildRoot -or
    $physicalOutput.StartsWith($physicalBuildRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputRoot physical path must be outside the generated build tree.'
}
if ($output -eq $buildRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) -or
    $output.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputRoot must be outside the generated build tree.'
}
$auditFiles = @(Get-ChildItem -LiteralPath (Join-Path $project 'doc') -Filter '11-Windows*.md' -File)
$guideFiles = @(Get-ChildItem -LiteralPath (Join-Path $project 'doc') -Filter '12-Windows*.md' -File)
if ($auditFiles.Count -ne 1 -or $guideFiles.Count -ne 1) { throw 'Expected exactly one audit and one preview guide.' }
$audit = $auditFiles[0].FullName
$guide = $guideFiles[0].FullName
foreach ($required in @($audit, $guide, (Join-Path $project 'pubspec.lock'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing packaging input: $required" }
}
$licenseDirectory = Join-Path $project 'doc\licenses'
$physicalLicenseDirectory = (Get-HanMusicPhysicalPath $licenseDirectory).TrimEnd('\')
if ($physicalOutput -eq $physicalLicenseDirectory -or
    $physicalOutput.StartsWith($physicalLicenseDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputRoot must be outside the license input directory.'
}
foreach ($licenseFile in @('README.md','mpv-Copyright.txt','LGPL-2.1.txt','FFmpeg-LICENSE-n6.0.md',
        'LGPL-3.0.txt','GPL-3.0.txt','hls.js-1.4.10-LICENSE.txt','Apache-2.0.txt','JNI-AOSP-ATTRIBUTION.txt')) {
    $requiredLicense = Join-Path $licenseDirectory $licenseFile
    if (-not (Test-Path -LiteralPath $requiredLicense -PathType Leaf) -or
        (Get-Item -LiteralPath $requiredLicense).Length -eq 0) { throw "Missing required license material: $licenseFile" }
}
$flutter = (Get-Command flutter -ErrorAction Stop).Source
$sdkVersionFile = Join-Path (Split-Path -Parent (Split-Path -Parent $flutter)) 'bin\cache\flutter.version.json'
if (-not (Test-Path -LiteralPath $sdkVersionFile)) { throw 'Unable to locate Flutter SDK version metadata.' }
$sdkVersion = Get-Content -LiteralPath $sdkVersionFile -Raw | ConvertFrom-Json
$utf8 = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$buildLog = Join-Path $output "$PackageName-build.txt"

Push-Location -LiteralPath $project
try {
    # Remove only the checked, generated Release directory. Rebuild main.dart
    # every time so a diagnostic entry or stale DLL cannot enter the package.
    if (Test-Path -LiteralPath $release) {
        Assert-HanMusicBuildPath -Project $project -Release $release
        Assert-HanMusicNoReparseTree -Root $release
        $resolvedRelease = Get-HanMusicPhysicalPath $release
        $wantedExe = Get-HanMusicPhysicalPath (Join-Path $release 'han_music.exe')
        $active = @(Get-Process -Name han_music -ErrorAction SilentlyContinue | Where-Object {
            if ([string]::IsNullOrEmpty($_.Path)) { throw 'Unable to inspect a running HanMusic process.' }
            (Get-HanMusicPhysicalPath $_.Path) -eq $wantedExe
        })
        if ($active.Count -gt 0) { throw 'Close the app running from the build directory before packaging.' }
        Remove-Item -LiteralPath $resolvedRelease -Recurse -Force
    }
    Invoke-HanMusicNativeLogged -FilePath $flutter -Arguments @('build','windows','--release','--no-pub','-t','lib/main.dart') -LogPath $buildLog
    foreach ($relative in @('han_music.exe', 'flutter_windows.dll', 'libmpv-2.dll',
            'media_kit_libs_windows_audio_plugin.dll', 'data\app.so', 'data\icudtl.dat',
            'data\flutter_assets\NOTICES.Z')) {
        if (-not (Test-Path -LiteralPath (Join-Path $release $relative) -PathType Leaf)) {
            throw "Incomplete Flutter Release output: $relative"
        }
    }
    Copy-Item -LiteralPath $release -Destination $stage -Recurse
    Copy-Item -LiteralPath $guide -Destination (Join-Path $stage 'README.md')
    Copy-Item -LiteralPath $audit -Destination (Join-Path $stage 'DISTRIBUTION-AUDIT.md')
    Copy-Item -LiteralPath (Join-Path $project 'pubspec.lock') -Destination (Join-Path $stage 'DEPENDENCIES.lock')
    if (Test-Path -LiteralPath $licenseDirectory) {
        Copy-Item -LiteralPath $licenseDirectory -Destination (Join-Path $stage 'licenses') -Recurse
        $licenseIndex = Join-Path $stage 'licenses\README.md'
        if (Test-Path -LiteralPath $licenseIndex) {
            $originalLink = '../' + [IO.Path]::GetFileName($audit)
            $licenseIndexText = [IO.File]::ReadAllText($licenseIndex).Replace($originalLink, '../DISTRIBUTION-AUDIT.md')
            [IO.File]::WriteAllText($licenseIndex, $licenseIndexText, $utf8)
        }
    }

    $compressed = [IO.File]::OpenRead((Join-Path $stage 'data\flutter_assets\NOTICES.Z'))
    $notices = [IO.File]::Create((Join-Path $stage 'THIRD-PARTY-NOTICES.txt'))
    $gzip = New-Object IO.Compression.GZipStream($compressed, [IO.Compression.CompressionMode]::Decompress)
    try { $gzip.CopyTo($notices) } finally { $gzip.Dispose(); $notices.Dispose(); $compressed.Dispose() }

    # Keep the launchers ASCII so stock Windows PowerShell 5.1 can read them.
    [IO.File]::WriteAllText((Join-Path $stage 'Start-HanMusic.ps1'), @'
param([string]$DataDirectory = (Join-Path $PSScriptRoot 'UserData'))
$ErrorActionPreference = 'Stop'
if ($DataDirectory -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+(?:\\|$))') { throw 'DataDirectory must be absolute.' }
$dataPath = [IO.Path]::GetFullPath($DataDirectory)
New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
$probe = Join-Path $dataPath ('.write-test-' + [Guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($probe, 'write-check')
Remove-Item -LiteralPath $probe
$env:HANMUSIC_DATA_DIR = $dataPath
Start-Process -FilePath (Join-Path $PSScriptRoot 'han_music.exe') -WorkingDirectory $PSScriptRoot
'@, $utf8)
    [IO.File]::WriteAllText((Join-Path $stage 'Start-HanMusic.cmd'), @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-HanMusic.ps1"
if errorlevel 1 pause
'@, $utf8)
    [IO.File]::WriteAllText((Join-Path $stage 'PREVIEW-STATUS.txt'), @'
HanMusic Windows x64 development preview; not an approved public release.
Read README.md and DISTRIBUTION-AUDIT.md before testing or redistribution.
Native system UI, real sleep/resume, clean-machine validation, project licensing,
and complete native dependency source/notice requirements remain release gates.
No SDK, Java runtime, or Microsoft Visual C++ redistributable is bundled.
Launch with Start-HanMusic.cmd to store data in the adjacent UserData folder.
'@, $utf8)

    $commit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to identify source revision.' }
    $dirty = @(& git status --porcelain).Count -gt 0
    $version = ((Select-String -LiteralPath (Join-Path $project 'pubspec.yaml') -Pattern '^version:').Line -replace '^version:\s*','').Trim()
    $inventory = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName | ForEach-Object {
        [ordered]@{path=$_.FullName.Substring($stage.Length + 1).Replace('\','/'); bytes=$_.Length;
            sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    $manifest = [ordered]@{
        schemaVersion=1; name='HanMusic'; version=$version; channel='development-preview';
        target='windows-x64'; entryPoint='lib/main.dart'; gitCommit=$commit; gitDirty=$dirty;
        sdk=[ordered]@{flutter=$sdkVersion.frameworkVersion; frameworkRevision=$sdkVersion.frameworkRevision;
            engineRevision=$sdkVersion.engineRevision; dart=$sdkVersion.dartSdkVersion};
        builtAt=(Get-Date).ToUniversalTime().ToString('o'); publicReleaseReady=$false;
        files=$inventory; inventoryExcludes=@('BUILD-MANIFEST.json','UserData');
        notes='Inventory hashes cover the packaged files before first launch. ZIP SHA256 also covers the manifest.'
    }
    [IO.File]::WriteAllText((Join-Path $stage 'BUILD-MANIFEST.json'), ($manifest | ConvertTo-Json -Depth 8), $utf8)
    Compress-Archive -LiteralPath $stage -DestinationPath $archive -CompressionLevel Optimal
    $zipHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$archive.sha256", "$zipHash  $PackageName.zip`r`n", $utf8)
    [ordered]@{packageDirectory=$stage; archive=$archive; sha256=$zipHash; bytes=(Get-Item -LiteralPath $archive).Length;
        fileCount=$inventory.Count + 1; channel='development-preview'; publicReleaseReady=$false} | ConvertTo-Json
} finally { Pop-Location }
