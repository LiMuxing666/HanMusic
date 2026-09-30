[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-NoLinkAncestors {
    param([string]$Path)
    $cursor = [System.IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($cursor)) {
        # Test-Path can report false for a dangling symbolic link. Inspect the
        # existing directory entry itself, including links with missing targets.
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Links are not accepted in the output path: $cursor"
            }
        }
        $parent = [System.IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
}

if ($OutputDirectory -notmatch '^[dD]:[\\/]') {
    throw 'OutputDirectory must be an absolute D: path.'
}
$output = [System.IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if ($output.Length -le 3) { throw 'The drive root is not an output directory.' }
Assert-NoLinkAncestors $output
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$repoItem = Get-Item -LiteralPath $repo -Force
$repoPaths = @($repo)
if (($repoItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    $repoPaths += @($repoItem.Target)
}
foreach ($repoPath in $repoPaths) {
    $root = [System.IO.Path]::GetFullPath($repoPath).TrimEnd('\')
    if ($output.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $output.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Generated native artifacts must stay outside the repository.'
    }
}

$markerName = '.hanmusic-process-loopback-build'
$markerText = 'HanMusic process-loopback diagnostic build v1'
$marker = Join-Path $output $markerName
$knownNames = @($markerName, 'process_loopback_probe.dll', 'process_loopback_probe.obj',
    'process_loopback_probe.lib', 'process_loopback_probe.exp', 'process_loopback_probe.pdb',
    'process_loopback_self_test.exe', 'process_loopback_self_test.obj',
    'process_loopback_self_test.lib', 'process_loopback_self_test.exp',
    'process_loopback_self_test.pdb', 'compile.log', 'build-report.json',
    'self-test.json', 'self-test.stderr.txt')
if (Test-Path -LiteralPath $output) {
    if (-not (Test-Path -LiteralPath $output -PathType Container)) {
        throw 'OutputDirectory exists and is not a directory.'
    }
    $existing = @(Get-ChildItem -LiteralPath $output -Force)
    if ($existing.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
            [System.IO.File]::ReadAllText($marker) -cne $markerText) {
            throw 'Refusing to overwrite a directory without this generator marker.'
        }
        foreach ($entry in $existing) {
            if ($entry.PSIsContainer -or $entry.Name -notin $knownNames -or
                ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to overwrite an unrecognized output entry: $($entry.Name)"
            }
        }
    }
} else {
    New-Item -ItemType Directory -Path $output | Out-Null
}
Assert-NoLinkAncestors $output
[System.IO.File]::WriteAllText($marker, $markerText, [System.Text.Encoding]::ASCII)

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'Existing vswhere.exe not found.' }
$vsRoot = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($vsRoot)) { throw 'Existing MSVC x64 tools not found.' }
$devShell = Join-Path $vsRoot 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
if (-not (Test-Path -LiteralPath $devShell -PathType Leaf)) { throw 'Existing VS developer shell not found.' }
Import-Module -Name $devShell
Enter-VsDevShell -VsInstallPath $vsRoot -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
$compiler = (Get-Command cl.exe -CommandType Application -ErrorAction Stop).Source
$source = Join-Path $PSScriptRoot 'native\process_loopback_probe.cpp'
$log = Join-Path $output 'compile.log'
[System.IO.File]::WriteAllText($log, '', [System.Text.Encoding]::UTF8)

function Invoke-Compiler {
    param([string[]]$Arguments)
    $savedPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 turns native stderr into ErrorRecords. The
        # compiler exit code is authoritative; retain both streams in the log.
        $ErrorActionPreference = 'Continue'
        & $compiler @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $log -Append
        $compilerExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($compilerExit -ne 0) { throw "MSVC failed with exit code $compilerExit; see $log" }
}

$dll = Join-Path $output 'process_loopback_probe.dll'
$selfTestExe = Join-Path $output 'process_loopback_self_test.exe'
$common = @('/nologo', '/std:c++17', '/EHsc', '/W4', '/O2', '/MT', '/utf-8',
    '/D_WIN32_WINNT=0x0A00', '/DNTDDI_VERSION=0x0A00000A', $source)
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
try {
    $env:TEMP = 'D:\dev\tmp'
    $env:TMP = 'D:\dev\tmp'
    if (-not (Test-Path -LiteralPath $env:TEMP -PathType Container)) {
        throw 'Existing D:\dev\tmp is required for compiler temporary files.'
    }
    Push-Location -LiteralPath $output
    try {
        Invoke-Compiler ($common + @('/LD', ('/Fo' + (Join-Path $output 'process_loopback_probe.obj')),
            '/link', ('/OUT:' + $dll), 'Ole32.lib', 'Mmdevapi.lib', 'Uuid.lib'))
        if ($SelfTest) {
            Invoke-Compiler ($common + @('/DHM_CAPTURE_SELF_TEST',
                ('/Fo' + (Join-Path $output 'process_loopback_self_test.obj')),
                '/link', ('/OUT:' + $selfTestExe), 'Ole32.lib', 'Mmdevapi.lib', 'Uuid.lib'))
        }
    } finally { Pop-Location }
} finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
}

$selfTestPassed = $null
if ($SelfTest) {
    $stdout = Join-Path $output 'self-test.json'
    $stderr = Join-Path $output 'self-test.stderr.txt'
    # The only target is this owned helper's own PID. It never plays audio.
    $helper = Start-Process -FilePath $selfTestExe -ArgumentList ('"' + $dll + '"') -WorkingDirectory $output -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    # Windows PowerShell 5.1 must retain the process handle before the process
    # exits, otherwise Process.ExitCode can remain null after WaitForExit().
    $null = $helper.Handle
    if (-not $helper.WaitForExit(20000)) {
        $helper.Kill()
        $helper.WaitForExit(3000) | Out-Null
        throw 'Owned non-rendering self-test exceeded its 20 second watchdog.'
    }
    $helper.WaitForExit()
    $helper.Refresh()
    $selfTestResult = Get-Content -LiteralPath $stdout -Raw | ConvertFrom-Json
    $selfTestPassed = $helper.ExitCode -eq 0 -and $selfTestResult.passed -eq $true -and
        $selfTestResult.beforeStop.frames -gt 0 -and
        $selfTestResult.beforeStop.capturedThroughQpc100ns -gt $selfTestResult.beforeStop.armQpc100ns
    if (-not $selfTestPassed) { throw "Non-rendering self-test failed; see $stdout" }
}
$report = [ordered]@{
    schemaVersion = 1
    dll = $dll
    dllSha256 = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant()
    sourceSha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    compiler = $compiler
    windowsSdkVersion = $env:WindowsSDKVersion
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    selfTestPassed = $selfTestPassed
    audioRenderedBySelfTest = $false
    captureScope = 'current-process-tree-only'
}
$reportPath = Join-Path $output 'build-report.json'
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding UTF8
$report | ConvertTo-Json -Depth 5 -Compress
