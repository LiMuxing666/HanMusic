# Filesystem-only helpers shared by the packager and its guard tests.
if (-not ('HanMusicPackagingPaths' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class HanMusicPackagingPaths {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,
        StringBuilder path, uint length, uint flags);
    public static string Resolve(string path) {
        using (var handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            var buffer = new StringBuilder(32768);
            var length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0 || length >= buffer.Capacity)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var value = buffer.ToString();
            if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
                return @"\\" + value.Substring(8);
            return value.StartsWith(@"\\?\") ? value.Substring(4) : value;
        }
    }
}
'@
}

function Get-HanMusicPhysicalPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    $suffix = New-Object 'System.Collections.Generic.Stack[string]'
    while (-not (Test-Path -LiteralPath $cursor)) {
        $suffix.Push([IO.Path]::GetFileName($cursor))
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) { throw 'No existing path ancestor.' }
        $cursor = $parent
    }
    $physical = [HanMusicPackagingPaths]::Resolve($cursor)
    while ($suffix.Count -gt 0) { $physical = Join-Path $physical $suffix.Pop() }
    return [IO.Path]::GetFullPath($physical)
}

function Assert-HanMusicBuildPath {
    param([string]$Project, [string]$Release)
    $relative = 'build\windows\x64\runner\Release'
    $expected = [IO.Path]::GetFullPath((Join-Path $Project $relative))
    if ([IO.Path]::GetFullPath($Release) -ne $expected) { throw 'Unexpected Release path.' }
    $cursor = $Project
    foreach ($part in $relative.Split('\')) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Refusing a reparse point below the project root.'
            }
        }
    }
    $physicalRoot = Get-HanMusicPhysicalPath $Project
    $physicalRelease = Get-HanMusicPhysicalPath $Release
    if ($physicalRelease -ne [IO.Path]::GetFullPath((Join-Path $physicalRoot $relative))) {
        throw 'Release physical path escapes the project root.'
    }
}

function Assert-HanMusicNoReparseTree {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    $directories = New-Object 'System.Collections.Generic.Queue[string]'
    $directories.Enqueue($Root)
    while ($directories.Count -gt 0) {
        $directory = $directories.Dequeue()
        if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Refusing a reparse point in the generated tree.'
        }
        # Enumerate one directory at a time; never recurse through a link.
        foreach ($entry in Get-ChildItem -LiteralPath $directory -Force) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Refusing a reparse point in the generated tree.'
            }
            if ($entry.PSIsContainer) { $directories.Enqueue($entry.FullName) }
        }
    }
}

function Invoke-HanMusicNativeLogged {
    param([string]$FilePath, [string[]]$Arguments, [string]$LogPath)
    $previousPreference = $ErrorActionPreference
    $nativeExitCode = -1
    try {
        # Windows PowerShell 5.1 wraps native stderr as NativeCommandError even
        # for exit 0. Preserve it in the log and decide success by the exit code.
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        & $FilePath @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $LogPath -ErrorAction Stop
        $nativeExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($nativeExitCode -ne 0) { throw "Native command failed with exit code $nativeExitCode." }
}

function Get-HanMusicRuntimeRequirements {
    param([Parameter(Mandatory=$true)][string]$CMakeCache)
    # Use the toolset that produced this build, not the installed redist or
    # whatever compiler happens to come first on the packaging shell's PATH.
    $cache = [IO.File]::ReadAllText($CMakeCache).Replace('\', '/')
    $linkerLines = @($cache -split '\r?\n' | Where-Object { $_ -match '^CMAKE_LINKER:FILEPATH=' })
    if ($linkerLines.Count -ne 1 -or
        $linkerLines[0] -notmatch '/VC/Tools/MSVC/(?<version>14\.\d+\.\d+)/bin/Host(?:x64|x86)/x64/link\.exe\s*$') {
        throw 'Unable to identify the x64 MSVC toolset from this build CMake cache.'
    }
    $minimumVersion = ([version]($Matches.version + '.0')).ToString(4)
    return [ordered]@{
        schemaVersion = 1
        target = 'windows-x64'
        minimumVCRuntimeVersion = $minimumVersion
        requiredVCRuntimeDlls = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
        deployment = 'central'
        downloadUrl = 'https://aka.ms/vc14/vc_redist.x64.exe'
        guidanceUrl = 'https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist'
    }
}
