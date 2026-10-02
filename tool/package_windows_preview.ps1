[CmdletBinding()]
param(
    [string]$ProjectDirectory = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputRoot = 'D:\dev\releases\HanMusic',
    [string]$PackageName = ('HanMusic-Windows-x64-M5-preview-' + (Get-Date -Format 'yyyyMMdd-HHmmss')),
    [switch]$ValidateDocumentationOnly
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
foreach ($required in @($audit, $guide, (Join-Path $project 'pubspec.lock'),
        (Join-Path $project 'pubspec.yaml'), (Join-Path $PSScriptRoot 'windows_runtime_check.ps1'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing packaging input: $required" }
}
$versionLines = @(Select-String -LiteralPath (Join-Path $project 'pubspec.yaml') -Pattern '^version:\s*([^\s#]+)\s*(?:#.*)?$')
if ($versionLines.Count -ne 1) { throw 'Expected exactly one pubspec version.' }
$version = $versionLines[0].Matches[0].Groups[1].Value
$guideText = [IO.File]::ReadAllText($guide)
$guideMarker = '<!-- HANMUSIC_PACKAGE_VERSION -->'
if ($guideText.IndexOf($guideMarker, [StringComparison]::Ordinal) -lt 0 -or
    $guideText.IndexOf($guideMarker, [StringComparison]::Ordinal) -ne
    $guideText.LastIndexOf($guideMarker, [StringComparison]::Ordinal)) {
    throw 'Preview guide must contain exactly one version insertion marker.'
}
$guideVersionLine = [regex]::Match($guideText, '(?m)^[^\r\n]*' + [regex]::Escape($guideMarker) + '[^\r\n]*$')
if (-not $guideVersionLine.Success) { throw 'Preview guide version marker must be on one line.' }
$versionPrefix = $guideVersionLine.Value.Substring(0,
    $guideVersionLine.Value.IndexOf($guideMarker, [StringComparison]::Ordinal))
$previewReadme = $guideText.Substring(0, $guideVersionLine.Index) + $versionPrefix + "**$version**" +
    $guideText.Substring($guideVersionLine.Index + $guideVersionLine.Length)
if ([regex]::IsMatch($previewReadme, '\]\((?!https?://|#)[^)]*\)', 'IgnoreCase')) {
    throw 'Preview guide contains a relative Markdown link; use a packaged target or repository URL.'
}
$auditText = [IO.File]::ReadAllText($audit).Replace('](./21-',
    '](https://github.com/LiMuxing666/HanMusic/blob/Windows_lmx/doc/21-')
if ([regex]::IsMatch($auditText, '\]\(\./[^)]*\)')) {
    throw 'Distribution audit contains an unshipped repository-local link.'
}
if ($ValidateDocumentationOnly) {
    [ordered]@{version=$version; readme=$previewReadme; audit=$auditText} | ConvertTo-Json -Depth 2
    return
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
    $runtimeRequirements = Get-HanMusicRuntimeRequirements -CMakeCache (Join-Path $project 'build\windows\x64\CMakeCache.txt')
    foreach ($relative in @('han_music.exe', 'flutter_windows.dll', 'libmpv-2.dll',
            'media_kit_libs_windows_audio_plugin.dll', 'data\app.so', 'data\icudtl.dat',
            'data\flutter_assets\NOTICES.Z')) {
        if (-not (Test-Path -LiteralPath (Join-Path $release $relative) -PathType Leaf)) {
            throw "Incomplete Flutter Release output: $relative"
        }
    }
    Copy-Item -LiteralPath $release -Destination $stage -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows_runtime_check.ps1') -Destination (Join-Path $stage 'Check-Runtime.ps1')
    [IO.File]::WriteAllText((Join-Path $stage 'RUNTIME-REQUIREMENTS.json'), ($runtimeRequirements | ConvertTo-Json -Depth 4), $utf8)
    [IO.File]::WriteAllText((Join-Path $stage 'README.md'), $previewReadme, $utf8)
    [IO.File]::WriteAllText((Join-Path $stage 'DISTRIBUTION-AUDIT.md'), $auditText, $utf8)
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

    # Resolve package-local Markdown references after the final file layout is known.
    $stagePrefix = [IO.Path]::GetFullPath($stage).TrimEnd('\') + '\'
    foreach ($relativeDoc in @('README.md','DISTRIBUTION-AUDIT.md','licenses\README.md')) {
        $docPath = Join-Path $stage $relativeDoc
        foreach ($link in [regex]::Matches([IO.File]::ReadAllText($docPath), '\]\(([^)]+)\)')) {
            $target = $link.Groups[1].Value.Split('#')[0]
            if (-not $target -or $target -match '^[a-z][a-z0-9+.-]*:') { continue }
            $resolved = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $docPath) $target.Replace('/', '\')))
            if (-not $resolved.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                throw "Packaged Markdown link target is missing or outside the package: $relativeDoc -> $target"
            }
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
$runtimeJson = & (Join-Path $PSScriptRoot 'Check-Runtime.ps1') -PackageDirectory $PSScriptRoot -AsJson
$runtimeExit = $LASTEXITCODE
$runtimeStatus = ($runtimeJson -join "`n") | ConvertFrom-Json
if ($runtimeExit -ne 0 -or $runtimeStatus.passed -ne $true) {
    foreach ($issue in $runtimeStatus.issues) { Write-Output $issue.message }
    Write-Output $runtimeStatus.installationGuidance
    Write-Output ('Official x64 installer: ' + $runtimeStatus.downloadUrl)
    throw 'Runtime check failed. Follow the instructions above, then run Start-HanMusic.cmd again.'
}
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
Check-Runtime.ps1 reads the required x64 runtime DLL versions before launch.
The launcher does not download, install, or change system prerequisites.
Launch with Start-HanMusic.cmd to store data in the adjacent UserData folder.
'@, $utf8)

    $commit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to identify source revision.' }
    $dirty = @(& git status --porcelain).Count -gt 0
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
        runtimeRequirements=$runtimeRequirements;
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
