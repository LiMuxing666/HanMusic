# Combine existing notice materials without rewriting their original bytes.
. (Join-Path $PSScriptRoot 'windows_packaging_utils.ps1')

function Write-HanMusicThirdPartyNotices {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PackageDirectory)

    $root = (Resolve-Path -LiteralPath $PackageDirectory -ErrorAction Stop).Path.TrimEnd('\')
    Assert-HanMusicNoReparseTree -Root $root
    $output = Join-Path $root 'THIRD_PARTY_NOTICES.txt'
    if (Test-Path -LiteralPath $output) { throw 'Combined notices output already exists.' }
    $compressedPath = Join-Path $root 'data\flutter_assets\NOTICES.Z'
    $licenseRoot = Join-Path $root 'licenses'
    $requiredLicenses = @('README.md','mpv-Copyright.txt','LGPL-2.1.txt','FFmpeg-LICENSE-n6.0.md',
        'LGPL-3.0.txt','GPL-3.0.txt','hls.js-1.4.10-LICENSE.txt','Apache-2.0.txt','JNI-AOSP-ATTRIBUTION.txt')
    foreach ($name in $requiredLicenses) {
        $required = Join-Path $licenseRoot $name
        if (-not (Test-Path -LiteralPath $required -PathType Leaf) -or (Get-Item -LiteralPath $required).Length -eq 0) {
            throw "Missing required notice material: licenses/$name"
        }
    }
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $compressed = [IO.File]::OpenRead($compressedPath)
    $expanded = New-Object IO.MemoryStream
    $gzip = New-Object IO.Compression.GZipStream($compressed, [IO.Compression.CompressionMode]::Decompress)
    try { $gzip.CopyTo($expanded); $flutterBytes = $expanded.ToArray() }
    finally { $gzip.Dispose(); $expanded.Dispose(); $compressed.Dispose() }
    if ($flutterBytes.Length -eq 0) { throw 'Flutter notices are empty.' }
    $null = $utf8.GetString($flutterBytes)

    $licensePaths = [string[]]@(Get-ChildItem -LiteralPath $licenseRoot -File -Recurse | Select-Object -ExpandProperty FullName)
    [Array]::Sort($licensePaths, [StringComparer]::Ordinal)
    $materials = @()
    foreach ($path in $licensePaths) {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -eq 0) { throw 'Supplemental notice material is empty.' }
        $null = $utf8.GetString($bytes)
        $materials += [pscustomobject]@{path=$path.Substring($root.Length + 1).Replace('\','/'); bytes=$bytes;
            sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $components = @(
        @{path='flutter_windows.dll'; required=$true; materials='Flutter/engine notices in section 1.'},
        @{path='libmpv-2.dll'; required=$true; materials='mpv-Copyright.txt, LGPL-2.1.txt, FFmpeg-LICENSE-n6.0.md, LGPL-3.0.txt and GPL-3.0.txt. This DLL embeds FFmpeg; exact patched sources and static dependency materials remain incomplete.'},
        @{path='media_kit_libs_windows_audio_plugin.dll'; required=$true; materials='Wrapper plugin package notices in section 1; these do not replace the libmpv/FFmpeg materials.'},
        @{path='dartjni.dll'; required=$false; materials='JNI package notices in section 1; JNI-AOSP-ATTRIBUTION.txt and Apache-2.0.txt supplement its native AOSP attribution.'},
        @{path='data/flutter_assets/packages/media_kit/assets/web/hls1.4.10.js'; required=$false; materials='hls.js-1.4.10-LICENSE.txt and Apache-2.0.txt.'}
    )
    $nativeEntries = @()
    foreach ($component in $components) {
        $componentPath = Join-Path $root $component.path.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $componentPath -PathType Leaf)) {
            if ($component.required) { throw "Missing packaged native component: $($component.path)" }
            continue
        }
        $nativeEntries += [pscustomobject]@{path=$component.path;
            sha256=(Get-FileHash -LiteralPath $componentPath -Algorithm SHA256).Hash.ToLowerInvariant();
            materials=$component.materials}
    }

    $header = New-Object Text.StringBuilder
    $null = $header.Append("HanMusic third-party notices`n`n")
    $null = $header.Append("This file combines the current build's Flutter notices and the collected supplemental materials.`n")
    $null = $header.Append("Original compressed notices and individual licenses are retained in the package.`n")
    $null = $header.Append("It does not grant a HanMusic project license or certify public-release compliance.`n")
    $null = $header.Append("Complete native corresponding sources, patches, recipes and static dependency notices remain release gates.`n")
    $null = $header.Append("See DISTRIBUTION-AUDIT.md and licenses/README.md for provenance and unresolved items.`n`n")
    $null = $header.Append("Packaged native components and shipped assets (actual SHA-256):`n")
    foreach ($entry in $nativeEntries) {
        $null = $header.Append("$($entry.path)`nSHA-256: $($entry.sha256)`nMaterials: $($entry.materials)`n`n")
    }
    $null = $header.Append("=== SECTION 1: Flutter/Dart/engine/package notices ===`nSource: data/flutter_assets/NOTICES.Z (gzip expanded, original bytes)`n`n")
    # Validate all inputs before creating a new output; never truncate an existing file.
    $stream = [IO.File]::Open($output, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $headerBytes = $utf8.GetBytes($header.ToString())
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        $stream.Write($flutterBytes, 0, $flutterBytes.Length)
        foreach ($material in $materials) {
            $sectionBytes = $utf8.GetBytes("`n`n=== SECTION 2: $($material.path) ===`nSource SHA-256: $($material.sha256)`n`n")
            $stream.Write($sectionBytes, 0, $sectionBytes.Length)
            $stream.Write($material.bytes, 0, $material.bytes.Length)
        }
    } finally { $stream.Dispose() }
    return [ordered]@{path='THIRD_PARTY_NOTICES.txt'; supplementalFileCount=$materials.Count;
        nativeComponentCount=$nativeEntries.Count;
        compressedFlutterSha256=(Get-FileHash -LiteralPath $compressedPath -Algorithm SHA256).Hash.ToLowerInvariant()}
}
