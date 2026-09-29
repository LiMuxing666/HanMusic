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
Write-Output '9 packaging guard checks passed; external marker, existing preview and build executable preserved.'
