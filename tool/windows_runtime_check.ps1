param(
    [string]$PackageDirectory = $PSScriptRoot,
    [switch]$AsJson
)

# Read-only preflight. No DLL is loaded, downloaded, installed, or executed.
# This file is copied into a preview package as Check-Runtime.ps1.

function Get-HanMusicRuntimePlatform {
    $native = 'unknown'
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        if (([System.Management.Automation.PSTypeName]'System.Runtime.InteropServices.RuntimeInformation').Type) {
            $native = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
        } else {
            # Read the machine setting, not the caller's overridable process env.
            $machine = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')
            switch ($machine) {
                'AMD64' { $native = 'x64' }
                'ARM64' { $native = 'arm64' }
                'x86' { $native = 'x86' }
            }
        }
    }
    [pscustomobject]@{
        operatingSystem = [Environment]::OSVersion.Platform.ToString()
        architecture = $native
        is64BitProcess = [Environment]::Is64BitProcess
        windowsDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    }
}

function Get-HanMusicRuntimeDllFacts {
    param(
        [Parameter(Mandatory=$true)][string]$LiteralPath,
        [scriptblock]$VersionReader = { param($file) [Diagnostics.FileVersionInfo]::GetVersionInfo($file) }
    )
    $ErrorActionPreference = 'Stop'
    try { $entry = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] {
        return [pscustomobject]@{ exists = $false }
    }
    catch {
        # Access failures must not look like absence and enable a fallback.
        return [pscustomobject]@{ exists = $true; errorCode = 'unreadable'; error = $_.Exception.Message }
    }
    if ($entry.PSIsContainer) {
        return [pscustomobject]@{ exists = $true; errorCode = 'invalid-file'; error = 'Expected a DLL file, found a directory.' }
    }
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($entry.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = New-Object IO.BinaryReader($stream)
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw [IO.InvalidDataException]::new('Missing DOS header.') }
        $stream.Position = 0x3C
        $offset = $reader.ReadUInt32()
        if ($offset -lt 64 -or ([long]$offset + 26) -gt $stream.Length) { throw [IO.InvalidDataException]::new('Invalid PE header offset.') }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw [IO.InvalidDataException]::new('Missing PE signature.') }
        $machine = $reader.ReadUInt16()
        $stream.Position = [long]$offset + 20
        $optionalSize = $reader.ReadUInt16()
        if ($optionalSize -lt 2 -or ([long]$offset + 24 + $optionalSize) -gt $stream.Length) {
            throw [IO.InvalidDataException]::new('Truncated PE optional header.')
        }
        $stream.Position = [long]$offset + 24
        $magic = $reader.ReadUInt16()
        if (($machine -eq 0x8664 -and $magic -ne 0x020B) -or ($machine -eq 0x014C -and $magic -ne 0x010B)) {
            throw [IO.InvalidDataException]::new('PE machine and optional header disagree.')
        }
        $version = & $VersionReader $entry.FullName
        if ([string]::IsNullOrWhiteSpace($version.FileVersion)) {
            return [pscustomobject]@{ exists = $true; machine = $machine; errorCode = 'missing-version'; error = 'No numeric FileVersion resource.' }
        }
        $numeric = '{0}.{1}.{2}.{3}' -f $version.FileMajorPart, $version.FileMinorPart, $version.FileBuildPart, $version.FilePrivatePart
        $parsed = [version]$numeric
        return [pscustomobject]@{ exists = $true; machine = $machine; fileVersion = $parsed.ToString(4) }
    }
    catch [IO.InvalidDataException] {
        return [pscustomobject]@{ exists = $true; errorCode = 'invalid-pe'; error = $_.Exception.Message }
    }
    catch {
        return [pscustomobject]@{ exists = $true; errorCode = 'unreadable'; error = $_.Exception.Message }
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-HanMusicRuntimeRequirements {
    param([Parameter(Mandatory=$true)][string]$LiteralPath)
    $ErrorActionPreference = 'Stop'
    $entry = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    if ($entry.PSIsContainer -or $entry.Length -gt 65536) { throw 'Requirements must be a JSON file no larger than 64 KiB.' }
    $raw = [IO.File]::ReadAllText($entry.FullName)
    $value = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    if ($null -eq $value -or $value -isnot [pscustomobject]) { throw 'Requirements must be a JSON object.' }
    $expected = @('schemaVersion', 'target', 'minimumVCRuntimeVersion', 'requiredVCRuntimeDlls', 'deployment', 'downloadUrl', 'guidanceUrl')
    $keys = @($value.PSObject.Properties.Name)
    if ($keys.Count -ne $expected.Count) { throw 'Unexpected requirements fields.' }
    foreach ($key in $keys) {
        if ($expected -cnotcontains $key) { throw 'Unexpected requirements field name.' }
    }
    # The schema is flat; only these literal field names are accepted. Also
    # reject duplicate keys that ConvertFrom-Json would otherwise overwrite.
    $rawKeys = [regex]::Matches($raw, '"(?:[^"\\]|\\.)*"\s*:')
    if ($rawKeys.Count -ne $expected.Count) { throw 'Duplicate or invalid requirements fields.' }
    foreach ($key in $expected) {
        if ([regex]::Matches($raw, ('"' + [regex]::Escape($key) + '"\s*:')).Count -ne 1) { throw 'Requirements field names must be unique and literal.' }
    }
    if (($value.schemaVersion -isnot [int] -and $value.schemaVersion -isnot [long]) -or $value.schemaVersion -ne 1) { throw 'Unsupported requirements schemaVersion.' }
    if ($value.target -cne 'windows-x64' -or $value.deployment -cne 'central') { throw 'Unsupported runtime target or deployment.' }
    if ($value.minimumVCRuntimeVersion -isnot [string] -or $value.minimumVCRuntimeVersion -cnotmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}\.\d{1,5}$') { throw 'Expected a four-part numeric minimumVCRuntimeVersion.' }
    $minimum = [version]$value.minimumVCRuntimeVersion
    $versionParts = @($minimum.Major, $minimum.Minor, $minimum.Build, $minimum.Revision)
    if ($minimum.Major -ne 14 -or @($versionParts | Where-Object { $_ -gt 65535 }).Count -ne 0) { throw 'Expected a VC 14 runtime version with valid numeric parts.' }
    $required = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
    if ($value.requiredVCRuntimeDlls -isnot [array] -or $value.requiredVCRuntimeDlls.Count -ne 3) { throw 'Expected the three required VC runtime DLL names.' }
    $seen = @{}
    foreach ($dll in $value.requiredVCRuntimeDlls) {
        if ($dll -isnot [string] -or $required -cnotcontains $dll -or $seen.ContainsKey($dll)) { throw 'Invalid or repeated required VC runtime DLL name.' }
        $seen[$dll] = $true
    }
    if ($value.downloadUrl -cne 'https://aka.ms/vc14/vc_redist.x64.exe' -or
        $value.guidanceUrl -cne 'https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist') { throw 'Expected the official Microsoft x64 runtime links.' }
    return $value
}

function Get-HanMusicRuntimeStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$PackageDirectory,
        # Injection points are for isolated tests; the CLI never accepts them.
        [scriptblock]$PlatformReader = { Get-HanMusicRuntimePlatform },
        [scriptblock]$DllReader = { param($file) Get-HanMusicRuntimeDllFacts -LiteralPath $file }
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $issues = New-Object 'System.Collections.Generic.List[object]'
    $report = [ordered]@{
        schemaVersion = 1; passed = $false; exitCode = 3; status = 'configuration-error'
        packageDirectory = $PackageDirectory; requirementsPath = $null
        minimumVCRuntimeVersion = $null; architecture = 'unknown'; processArchitecture = 'unknown'
        systemRuntimeDirectory = $null; checks = @(); issues = @()
        downloadUrl = 'https://aka.ms/vc14/vc_redist.x64.exe'
        guidanceUrl = 'https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist'
        installationGuidance = 'For missing or old runtime files, install the official Microsoft Visual C++ x64 Redistributable, then rerun this check. A broken app-local DLL must be corrected in the package; installing centrally cannot bypass it.'
        limitations = @('Read-only PE and numeric FileVersion checks only; no DLL is loaded.', 'A pass does not prove application startup or clean-machine compatibility.', 'ARM64 is not validated for this preview. JNI and jvm.dll are not startup prerequisites checked by this tool.')
    }
    try {
        $directory = Get-Item -LiteralPath $PackageDirectory -Force -ErrorAction Stop
        if (-not $directory.PSIsContainer) { throw 'PackageDirectory must be a directory.' }
        $report.packageDirectory = $directory.FullName
        $report.requirementsPath = Join-Path $directory.FullName 'RUNTIME-REQUIREMENTS.json'
        $requirements = Read-HanMusicRuntimeRequirements -LiteralPath $report.requirementsPath
        $report.minimumVCRuntimeVersion = $requirements.minimumVCRuntimeVersion
        $minimum = [version]$requirements.minimumVCRuntimeVersion
    } catch {
        $issues.Add([pscustomobject]@{ code = 'invalid-requirements'; message = $_.Exception.Message })
        $report.issues = $issues.ToArray()
        return [pscustomobject]$report
    }
    try {
        $platform = & $PlatformReader
        $report.architecture = [string]$platform.architecture
        $report.processArchitecture = if ($platform.is64BitProcess) { 'x64' } else { 'x86' }
        if ($platform.operatingSystem -ne 'Win32NT' -or $platform.architecture -ne 'x64') {
            $report.status = 'requirements-not-met'; $report.exitCode = 2
            $issues.Add([pscustomobject]@{ code = 'unsupported-platform'; message = 'This preview requires native Windows x64. ARM64 and other platforms are not validated or accepted.' })
            $report.issues = $issues.ToArray()
            return [pscustomobject]$report
        }
        if (-not [IO.Path]::IsPathRooted($platform.windowsDirectory)) { throw 'Unable to determine the Windows directory.' }
        $report.systemRuntimeDirectory = Join-Path $platform.windowsDirectory $(if ($platform.is64BitProcess) { 'System32' } else { 'Sysnative' })
        $probeFailure = $false
        foreach ($name in $requirements.requiredVCRuntimeDlls) {
            $candidate = Join-Path $report.packageDirectory $name
            $resolution = 'app-local'
            $facts = & $DllReader $candidate
            if (-not $facts.exists) {
                $candidate = Join-Path $report.systemRuntimeDirectory $name
                $resolution = 'system'
                $facts = & $DllReader $candidate
            }
            $check = [ordered]@{ name = $name; path = $candidate; resolution = $resolution; exists = [bool]$facts.exists; machine = $null; fileVersion = $null; passed = $false; issue = $null }
            if (-not $facts.exists) { $check.issue = 'missing-dll' }
            elseif ($facts.PSObject.Properties['errorCode']) {
                $check.issue = [string]$facts.errorCode
                if ($check.issue -eq 'unreadable') { $probeFailure = $true }
            } else {
                $check.machine = '0x{0:X4}' -f [int]$facts.machine
                $check.fileVersion = [string]$facts.fileVersion
                if ($facts.machine -ne 0x8664) { $check.issue = 'wrong-dll-architecture' }
                elseif ([version]$facts.fileVersion -lt $minimum) { $check.issue = 'runtime-too-old' }
                else { $check.passed = $true }
            }
            if (-not $check.passed) {
                $issues.Add([pscustomobject]@{ code = $check.issue; dll = $name; path = $candidate; message = ('{0}: {1} ({2}); requires x64 PE and FileVersion >= {3}.' -f $name, $check.issue, $resolution, $minimum) })
            }
            $checks.Add([pscustomobject]$check)
        }
        $report.passed = $issues.Count -eq 0
        $report.status = if ($report.passed) { 'passed' } elseif ($probeFailure) { 'probe-error' } else { 'requirements-not-met' }
        $report.exitCode = if ($report.passed) { 0 } elseif ($probeFailure) { 3 } else { 2 }
    } catch {
        $report.passed = $false; $report.status = 'probe-error'; $report.exitCode = 3
        $issues.Add([pscustomobject]@{ code = 'probe-error'; message = $_.Exception.Message })
    }
    $report.checks = $checks.ToArray()
    $report.issues = $issues.ToArray()
    return [pscustomobject]$report
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Get-HanMusicRuntimeStatus -PackageDirectory $PackageDirectory
    if ($AsJson) {
        $result | ConvertTo-Json -Depth 8
    } else {
        Write-Output ('HanMusic runtime preflight: {0}' -f $result.status)
        foreach ($check in $result.checks) {
            Write-Output ('{0}: passed={1}, version={2}, machine={3}, path={4}' -f $check.name, $check.passed, $check.fileVersion, $check.machine, $check.path)
        }
        foreach ($issue in $result.issues) { Write-Output $issue.message }
        if (-not $result.passed) {
            Write-Output $result.installationGuidance
            Write-Output ('Official x64 installer: ' + $result.downloadUrl)
            Write-Output ('Microsoft guidance: ' + $result.guidanceUrl)
        }
        Write-Output 'This read-only result does not prove DLL loading, application startup, or clean-machine compatibility.'
    }
    exit $result.exitCode
}
