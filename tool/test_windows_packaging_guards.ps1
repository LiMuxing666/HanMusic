param([string]$ScratchDirectory = 'D:\dev\tmp\hanmusic-m5-package-guards')
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$packager = Join-Path $PSScriptRoot 'package_windows_preview.ps1'
. (Join-Path $PSScriptRoot 'windows_packaging_utils.ps1')
$scratch = [IO.Path]::GetFullPath($ScratchDirectory)
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$existing = Join-Path $scratch 'existing-preview'
New-Item -ItemType Directory -Path $existing -Force | Out-Null
$marker = Join-Path $existing 'preserve.txt'
[IO.File]::WriteAllText($marker, 'preserve existing preview')
$exe = Join-Path $project 'build\windows\x64\runner\Release\han_music.exe'
$before = if (Test-Path -LiteralPath $exe) { (Get-FileHash -LiteralPath $exe).Hash } else { $null }
$cases = @(
    @{Name='../escape'; Output=$scratch; Expected='plain file name'},
    @{Name='existing-preview'; Output=$scratch; Expected='Output already exists'},
    @{Name='inside-build'; Output=(Join-Path $project 'build\packaging'); Expected='outside the generated build tree'},
    @{Name='inside-licenses'; Output=(Join-Path $project 'doc\licenses'); Expected='outside the license input directory'}
)
foreach ($case in $cases) {
    $caught = $false
    try { & $packager -ProjectDirectory $project -OutputRoot $case.Output -PackageName $case.Name }
    catch {
        if ($_.Exception.Message -notlike "*$($case.Expected)*") { throw }
        $caught = $true
    }
    if (-not $caught) { throw "Guard did not reject: $($case.Name)" }
}
if ([IO.File]::ReadAllText($marker) -ne 'preserve existing preview') { throw 'Existing output changed.' }
$after = if (Test-Path -LiteralPath $exe) { (Get-FileHash -LiteralPath $exe).Hash } else { $null }
if ($before -ne $after) { throw 'A rejected request changed the build executable.' }

$fakeProject = Join-Path $scratch 'parent-link-project'
$outside = Join-Path $scratch 'outside-owned-fixture'
New-Item -ItemType Directory -Path $fakeProject,$outside -Force | Out-Null
$outsideRelease = Join-Path $outside 'windows\x64\runner\Release'
New-Item -ItemType Directory -Path $outsideRelease -Force | Out-Null
$outsideMarker = Join-Path $outsideRelease 'must-survive.txt'
[IO.File]::WriteAllText($outsideMarker, 'outside build stays untouched')
$buildLink = Join-Path $fakeProject 'build'
if (-not (Test-Path -LiteralPath $buildLink)) { New-Item -ItemType Junction -Path $buildLink -Target $outside | Out-Null }
$rejected = $false
try { & $packager -ProjectDirectory $fakeProject -OutputRoot $scratch -PackageName 'parent-link-case' }
catch {
    if ($_.Exception.Message -notlike '*reparse point below*') { throw }
    $rejected = $true
}
if (-not $rejected -or [IO.File]::ReadAllText($outsideMarker) -ne 'outside build stays untouched') {
    throw 'Parent junction guard failed.'
}
$insideTree = Join-Path $scratch 'inside-link-tree'
New-Item -ItemType Directory -Path $insideTree -Force | Out-Null
$insideLink = Join-Path $insideTree 'linked-assets'
if (-not (Test-Path -LiteralPath $insideLink)) { New-Item -ItemType Junction -Path $insideLink -Target $outside | Out-Null }
$rejected = $false
try { Assert-HanMusicNoReparseTree -Root $insideTree }
catch { if ($_.Exception.Message -notlike '*reparse point*') { throw }; $rejected = $true }
if (-not $rejected) { throw 'Nested junction guard failed.' }
$alias = Join-Path $scratch 'physical-alias'
if (-not (Test-Path -LiteralPath $alias)) { New-Item -ItemType Junction -Path $alias -Target $outside | Out-Null }
if ((Get-HanMusicPhysicalPath $outsideMarker) -ne
    (Get-HanMusicPhysicalPath (Join-Path $alias 'windows\x64\runner\Release\must-survive.txt'))) {
    throw 'Physical path aliases did not compare equally.'
}
$nativeFixture = Join-Path $scratch 'native-warning.ps1'
[IO.File]::WriteAllText($nativeFixture, 'param([int]$Code=0)' + "`r`n" + "[Console]::Error.WriteLine('warning-only')" + "`r`n" + 'exit $Code')
$nativeLog = Join-Path $scratch 'native-warning.txt'
$stockPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Invoke-HanMusicNativeLogged -FilePath $stockPowerShell -Arguments @('-NoProfile','-File',$nativeFixture,'-Code','0') -LogPath $nativeLog
if ([IO.File]::ReadAllText($nativeLog) -notlike '*warning-only*') { throw 'Native stderr was lost.' }
$rejected = $false
try { Invoke-HanMusicNativeLogged -FilePath $stockPowerShell -Arguments @('-NoProfile','-File',$nativeFixture,'-Code','7') -LogPath $nativeLog }
catch { if ($_.Exception.Message -notlike '*exit code 7*') { throw }; $rejected = $true }
if (-not $rejected) { throw 'Native nonzero exit was accepted.' }
$cacheFixture = Join-Path $scratch 'runtime-CMakeCache.txt'
$runtimeCases = @(
    @{Name='current-x64'; Content='CMAKE_LINKER:FILEPATH=C:/VS/VC/Tools/MSVC/14.37.32822/bin/Hostx64/x64/link.exe'; Expected='14.37.32822.0'},
    @{Name='newer-x86-host'; Content='CMAKE_LINKER:FILEPATH=D:\VS\VC\Tools\MSVC\14.50.12345\bin\Hostx86\x64\link.exe'; Expected='14.50.12345.0'},
    @{Name='missing-linker'; Content='CMAKE_BUILD_TYPE:STRING=Release'; Expected=$null},
    @{Name='ambiguous-linker'; Content=("CMAKE_LINKER:FILEPATH=C:/VS/VC/Tools/MSVC/14.37.32822/bin/Hostx64/x64/link.exe`nCMAKE_LINKER:FILEPATH=C:/VS/VC/Tools/MSVC/14.50.12345/bin/Hostx64/x64/link.exe"); Expected=$null},
    @{Name='arm64-target'; Content='CMAKE_LINKER:FILEPATH=C:/VS/VC/Tools/MSVC/14.37.32822/bin/Hostx64/arm64/link.exe'; Expected=$null},
    @{Name='malformed-version'; Content='CMAKE_LINKER:FILEPATH=C:/VS/VC/Tools/MSVC/latest/bin/Hostx64/x64/link.exe'; Expected=$null}
)
foreach ($case in $runtimeCases) {
    [IO.File]::WriteAllText($cacheFixture, $case.Content)
    $rejected = $false
    try { $requirements = Get-HanMusicRuntimeRequirements -CMakeCache $cacheFixture }
    catch {
        if ($null -ne $case.Expected -or $_.Exception.Message -notlike '*x64 MSVC toolset*') { throw }
        $rejected = $true
    }
    if ($null -eq $case.Expected) {
        if (-not $rejected) { throw "Invalid runtime toolset accepted: $($case.Name)" }
    } elseif ($requirements.minimumVCRuntimeVersion -ne $case.Expected -or
        $requirements.target -ne 'windows-x64' -or $requirements.requiredVCRuntimeDlls.Count -ne 3) {
        throw "Incorrect runtime requirements: $($case.Name)"
    }
}

# Inspect the README path without invoking Flutter or writing a preview package.
$guideFixture = Join-Path $scratch ('readme-fixture-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $guideFixture 'build'),(Join-Path $guideFixture 'doc') -Force | Out-Null
$auditSource = @(Get-ChildItem -LiteralPath (Join-Path $project 'doc') -Filter '11-Windows*.md' -File)
$guideSource = @(Get-ChildItem -LiteralPath (Join-Path $project 'doc') -Filter '12-Windows*.md' -File)
if ($auditSource.Count -ne 1 -or $guideSource.Count -ne 1) { throw 'Expected one audit and one preview guide fixture.' }
Copy-Item -LiteralPath $auditSource[0].FullName -Destination (Join-Path $guideFixture 'doc')
Copy-Item -LiteralPath $guideSource[0].FullName -Destination (Join-Path $guideFixture 'doc')
Copy-Item -LiteralPath (Join-Path $project 'pubspec.lock') -Destination $guideFixture
$futureVersion = '0.1.0-dev.99+99'
[IO.File]::WriteAllText((Join-Path $guideFixture 'pubspec.yaml'), "version: $futureVersion`n")
$guidePath = (Get-ChildItem -LiteralPath (Join-Path $guideFixture 'doc') -Filter '12-Windows*.md' -File).FullName
$originalGuide = [IO.File]::ReadAllText($guidePath)
foreach ($newline in @("`n", "`r`n")) {
    $normalizedGuide = $originalGuide.Replace("`r`n", "`n").Replace("`n", $newline)
    [IO.File]::WriteAllText($guidePath, $normalizedGuide)
    $newlineInspection = (& $packager -ProjectDirectory $guideFixture -OutputRoot $scratch -PackageName 'readme-newline-inspection' -ValidateDocumentationOnly) | ConvertFrom-Json
    $expectedLines = @($normalizedGuide.Split([string[]]@($newline), [StringSplitOptions]::None) | ForEach-Object {
        $markerIndex = $_.IndexOf('<!-- HANMUSIC_PACKAGE_VERSION -->', [StringComparison]::Ordinal)
        if ($markerIndex -ge 0) { $_.Substring(0, $markerIndex) + "**$futureVersion**" } else { $_ }
    })
    $expectedReadme = $expectedLines -join $newline
    if ($newlineInspection.readme -cne $expectedReadme) {
        throw 'README version rendering changed its original LF or CRLF line endings.'
    }
}
[IO.File]::WriteAllText($guidePath, $originalGuide)
$inspection = (& $packager -ProjectDirectory $guideFixture -OutputRoot $scratch -PackageName 'readme-inspection' -ValidateDocumentationOnly) | ConvertFrom-Json
if ($inspection.version -cne $futureVersion -or
    $inspection.readme -cnotmatch [regex]::Escape("**$futureVersion**") -or
    $inspection.readme.Contains('<!-- HANMUSIC_PACKAGE_VERSION -->') -or
    $inspection.readme -match '\]\((?!https?://|#)[^)]*\)' -or
    $inspection.audit -match '\]\(\./' -or
    $inspection.audit -notmatch 'https://github.com/LiMuxing666/HanMusic/blob/Windows_lmx/doc/21-') {
    throw 'Packaged documentation did not render the current version with safe links.'
}
[IO.File]::WriteAllText($guidePath, $originalGuide + "`n[missing](./missing.md)`n")
$rejected = $false
try { & $packager -ProjectDirectory $guideFixture -OutputRoot $scratch -PackageName 'readme-inspection' -ValidateDocumentationOnly | Out-Null }
catch { if ($_.Exception.Message -notlike '*relative Markdown link*') { throw }; $rejected = $true }
if (-not $rejected) { throw 'A broken relative README link was accepted.' }
[IO.File]::WriteAllText($guidePath, $originalGuide.Replace('<!-- HANMUSIC_PACKAGE_VERSION -->', '<!-- missing-version-marker -->'))
$rejected = $false
try { & $packager -ProjectDirectory $guideFixture -OutputRoot $scratch -PackageName 'readme-inspection' -ValidateDocumentationOnly | Out-Null }
catch { if ($_.Exception.Message -notlike '*version insertion marker*') { throw }; $rejected = $true }
if (-not $rejected) { throw 'A README without the version insertion marker was accepted.' }
$auditPath = (Get-ChildItem -LiteralPath (Join-Path $guideFixture 'doc') -Filter '11-Windows*.md' -File).FullName
[IO.File]::AppendAllText($auditPath, "`n[missing](./missing.md)`n")
[IO.File]::WriteAllText($guidePath, $originalGuide)
$rejected = $false
try { & $packager -ProjectDirectory $guideFixture -OutputRoot $scratch -PackageName 'readme-inspection' -ValidateDocumentationOnly | Out-Null }
catch { if ($_.Exception.Message -notlike '*unshipped repository-local link*') { throw }; $rejected = $true }
if (-not $rejected) { throw 'An unshipped audit link was accepted.' }
Write-Output '21 packaging guard checks passed; LF/CRLF README version and links, audit links, external marker, existing preview and build executable preserved.'
