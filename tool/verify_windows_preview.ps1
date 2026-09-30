[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Archive,
    [string]$VerificationRoot = 'D:\dev\tmp\hanmusic-m5-package-verification',
    [switch]$CheckDataDirectoryLock
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-AbsoluteDPath {
    param([string]$Value)
    if ($Value -notmatch '^[dD]:[\\/]') { throw 'A fully qualified D: path is required.' }
    return [IO.Path]::GetFullPath($Value)
}

function Assert-NoLinkedAncestors {
    param([string]$Value)
    $cursor = [IO.Path]::GetFullPath($Value)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Verification paths must not traverse junctions or symbolic links.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd([char]'\'))
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-SafeRelativeName {
    param([string]$Value, [bool]$AllowDirectory = $false)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'Empty archive or manifest path.' }
    $name = $Value.Replace('\', '/')
    if ($name.StartsWith('/') -or $name -match '[:<>"|?*\x00-\x1f\x7f]') {
        throw 'Archive or manifest contains an absolute or invalid Windows path.'
    }
    if ($AllowDirectory) { $name = $name.TrimEnd([char]'/') }
    foreach ($segment in $name.Split('/')) {
        if (-not $segment -or $segment -eq '.' -or $segment -eq '..' -or
            $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw 'Archive or manifest contains traversal or an ambiguous Windows path.'
        }
        if ($segment -ieq 'UserData') { throw 'A preview package must not contain UserData.' }
    }
    return $name
}

function Get-ContainedPath {
    param([string]$Root, [string]$Relative)
    $safe = Get-SafeRelativeName -Value $Relative
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd([char]'\') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $Root $safe.Replace('/', '\')))
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Manifest path escapes its package root.'
    }
    return $full
}

function Get-MatchingApp {
    param([string]$Executable, [datetime]$LaunchedAt, [int[]]$PreviousIds)
    foreach ($candidate in @(Get-Process -Name han_music -ErrorAction SilentlyContinue)) {
        try {
            if ($PreviousIds -contains $candidate.Id) { continue }
            $candidatePath = [IO.Path]::GetFullPath($candidate.Path)
            if (-not $candidatePath.Equals($Executable, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($candidate.StartTime.ToUniversalTime() -lt $LaunchedAt.AddSeconds(-2)) { continue }
            $candidate
        } catch {
            # A process may disappear between enumeration and reading its identity.
        }
    }
}

function Stop-ExactOwnedProcess {
    param([int]$Id, [string]$Executable, [long]$StartTicks)
    $live = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if ($null -eq $live) { return $true }
    try {
        if (-not ([IO.Path]::GetFullPath($live.Path)).Equals($Executable, [StringComparison]::OrdinalIgnoreCase) -or
            $live.StartTime.ToUniversalTime().Ticks -ne $StartTicks) {
            return $false
        }
        Stop-Process -InputObject $live -Force -ErrorAction Stop
        return $live.WaitForExit(5000)
    } catch {
        if ($null -eq (Get-Process -Id $Id -ErrorAction SilentlyContinue)) { return $true }
        return $false
    }
}

function Test-DataDirectoryLockRange {
    param([string]$LockFile)
    $stream = $null
    $acquired = $false
    try {
        # Open only: never create/truncate/write/delete the application's lock.
        # Open errors must not be mistaken for a successful lock-conflict test.
        $stream = [IO.File]::Open($LockFile, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        try {
            $stream.Lock(0L, 1L)
            $acquired = $true
        } catch {
            # PowerShell may wrap a .NET method's IOException. Inspect the
            # actual IO exception, and accept only ERROR_LOCK_VIOLATION (33).
            $exception = $_.Exception
            while ($null -ne $exception -and $exception -isnot [IO.IOException]) {
                $exception = $exception.InnerException
            }
            if ($null -eq $exception -or ($exception.HResult -band 0xffff) -ne 33) { throw }
            return [pscustomobject]@{acquired = $false; win32Error = 33; hResult = $exception.HResult}
        }
        return [pscustomobject]@{acquired = $true; win32Error = $null; hResult = $null}
    } finally {
        if ($null -ne $stream) {
            try {
                if ($acquired) { $stream.Unlock(0L, 1L) }
            } finally { $stream.Dispose() }
        }
    }
}

$root = Get-AbsoluteDPath -Value $VerificationRoot
Assert-NoLinkedAncestors -Value $root
if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root | Out-Null }
# The timestamp plus GUID makes every run independent; no existing output is removed.
$runName = '验收 包 ' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$runDirectory = Join-Path $root $runName
New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop | Out-Null
$extraction = Join-Path $runDirectory '展开 程序'
$reportPath = Join-Path $runDirectory 'verification.json'
$utf8 = New-Object Text.UTF8Encoding($false)
$report = [ordered]@{
    schemaVersion = 1; passed = $false; startedAt = [DateTime]::UtcNow.ToString('o');
    verificationDirectory = $runDirectory; archive = $Archive; checks = @(); error = $null;
    hostPowerShell = $PSVersionTable.PSVersion.ToString(); launcherPowerShell = $null;
    smoke = $null; cleanup = [ordered]@{appStopped = $null; helperStopped = $null};
    dataDirectoryLock = [ordered]@{requested = [bool]$CheckDataDirectoryLock; path = $null;
        heldWhileRunning = $null; conflictWin32Error = $null; conflictHResult = $null;
        releasedAfterStop = $null; releaseAttempts = 0; releaseWaitMs = $null; releaseError = $null};
    limitations = @('This is a development-machine integrity and eight-second process smoke check.',
        'Forced termination is not normal window close, persistence, or shutdown verification.',
        'No playback, native dialog, GUI interaction, actual sleep, device switch, or clean-machine test is performed.',
        'ZIP SHA256 checks integrity against its adjacent sidecar, not publisher authenticity or a digital signature.')
}
$helper = $null
$helperStartTicks = 0L
$helperExecutable = $null
$ownedApp = $null
$appStartTicks = 0L
$appExecutable = $null
$previousIds = @()
$launchTime = $null
$lockProbePath = $null
$lockCheckAttempted = $false

try {
    $archivePath = Get-AbsoluteDPath -Value $Archive
    Assert-NoLinkedAncestors -Value $archivePath
    if ([IO.Path]::GetExtension($archivePath) -ine '.zip' -or
        -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { throw 'Archive must be an existing ZIP file.' }
    $sidecar = "$archivePath.sha256"
    if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) { throw 'Adjacent ZIP.sha256 file is missing.' }
    Assert-NoLinkedAncestors -Value $sidecar
    $declared = [IO.File]::ReadAllText($sidecar)
    if ($declared -notmatch '^\s*([a-fA-F0-9]{64})[ \t]+\*?([^\r\n]+)\r?\n?\s*$') { throw 'Invalid SHA256 sidecar format.' }
    $expectedHash = $Matches[1]
    $declaredName = $Matches[2].Trim()
    if ($declaredName -cne [IO.Path]::GetFileName($archivePath)) { throw 'SHA256 sidecar names a different archive.' }
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if ($actualHash -ine $expectedHash) { throw 'ZIP SHA256 mismatch.' }
    $report.archive = $archivePath
    $report['archiveSha256'] = $actualHash.ToLowerInvariant()
    $report.checks += [ordered]@{name = 'zip_sha256'; passed = $true}

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $zipNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $uncompressedBytes = 0L
        if ($zip.Entries.Count -gt 100000) { throw 'ZIP has too many entries for this preview verifier.' }
        foreach ($entry in $zip.Entries) {
            $isDirectory = $entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')
            $name = Get-SafeRelativeName -Value $entry.FullName -AllowDirectory $isDirectory
            if (-not $zipNames.Add($name)) { throw 'ZIP has duplicate or case-colliding entry names.' }
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000) { throw 'ZIP symbolic-link entries are not supported.' }
            $uncompressedBytes += $entry.Length
            if ($entry.Length -gt 1GB -or $uncompressedBytes -gt 2GB) { throw 'ZIP exceeds the preview extraction size limit.' }
        }
    } finally { $zip.Dispose() }
    New-Item -ItemType Directory -Path $extraction | Out-Null
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extraction
    $extractedItems = @(Get-ChildItem -LiteralPath $extraction -Recurse -Force)
    if (@($extractedItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
        throw 'Extracted package contains a linked path.'
    }
    $manifestFiles = @($extractedItems | Where-Object { -not $_.PSIsContainer -and $_.Name -ieq 'BUILD-MANIFEST.json' })
    if ($manifestFiles.Count -ne 1) { throw 'Expected exactly one BUILD-MANIFEST.json in the ZIP.' }
    $manifestFile = $manifestFiles[0]
    $package = $manifestFile.DirectoryName
    $packagePrefix = $package.TrimEnd([char]'\') + '\'
    $allFiles = @($extractedItems | Where-Object { -not $_.PSIsContainer })
    if (@($allFiles | Where-Object { -not $_.FullName.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        throw 'ZIP contains files outside the manifest package root.'
    }
    $manifest = [IO.File]::ReadAllText($manifestFile.FullName) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.entryPoint -cne 'lib/main.dart' -or
        $manifest.publicReleaseReady -isnot [bool] -or $manifest.publicReleaseReady -ne $false) {
        throw 'Manifest must identify schema 1, lib/main.dart, and publicReleaseReady=false.'
    }
    $covered = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $verifiedBytes = 0L
    foreach ($item in @($manifest.files)) {
        if ($item.path -isnot [string] -or $item.sha256 -isnot [string] -or $item.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'Manifest has an invalid file record.'
        }
        $name = Get-SafeRelativeName -Value $item.path
        if ($name -ieq 'BUILD-MANIFEST.json' -or -not $covered.Add($name)) { throw 'Manifest has duplicate or self-referential file records.' }
        if ($item.bytes -is [bool] -or $item.bytes -isnot [ValueType] -or
            $item.bytes -lt 0 -or [math]::Floor([double]$item.bytes) -ne [double]$item.bytes) { throw 'Manifest byte length is invalid.' }
        $filePath = Get-ContainedPath -Root $package -Relative $name
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { throw 'A manifest file is missing.' }
        $file = Get-Item -LiteralPath $filePath
        if ($file.Length -ne $item.bytes) { throw 'A manifest file byte length differs.' }
        if ((Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash -ine $item.sha256) { throw 'A manifest file SHA256 differs.' }
        $verifiedBytes += $file.Length
    }
    foreach ($file in $allFiles) {
        if ($file.FullName -eq $manifestFile.FullName) { continue }
        $relative = $file.FullName.Substring($packagePrefix.Length).Replace('\', '/')
        if (-not $covered.Contains($relative)) { throw 'Package contains a file absent from the manifest.' }
    }
    if ($covered.Count -ne ($allFiles.Count - 1)) { throw 'Manifest and package file counts differ.' }
    $appExecutable = Get-ContainedPath -Root $package -Relative 'han_music.exe'
    $launcher = Get-ContainedPath -Root $package -Relative 'Start-HanMusic.cmd'
    $powerShellLauncher = Get-ContainedPath -Root $package -Relative 'Start-HanMusic.ps1'
    if (-not (Test-Path -LiteralPath $appExecutable -PathType Leaf) -or
        -not (Test-Path -LiteralPath $launcher -PathType Leaf) -or
        -not (Test-Path -LiteralPath $powerShellLauncher -PathType Leaf)) { throw 'Application or packaged launcher is missing.' }
    $report['packageDirectory'] = $package
    $report['manifest'] = [ordered]@{entryPoint = $manifest.entryPoint; publicReleaseReady = $manifest.publicReleaseReady;
        verifiedFiles = $covered.Count; verifiedBytes = $verifiedBytes; gitCommit = $manifest.gitCommit; gitDirty = $manifest.gitDirty}
    $report.checks += [ordered]@{name = 'complete_manifest_hashes_paths_and_no_userdata'; passed = $true}

    $systemPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $systemPowerShell -PathType Leaf)) { throw 'System Windows PowerShell is unavailable.' }
    $runtimeChecker = Join-Path $package 'Check-Runtime.ps1'
    $runtimeRequirementsPath = Join-Path $package 'RUNTIME-REQUIREMENTS.json'
    $hasRuntimeDeclaration = $null -ne $manifest.PSObject.Properties['runtimeRequirements']
    $hasRuntimeChecker = Test-Path -LiteralPath $runtimeChecker -PathType Leaf
    $hasRuntimeRequirements = Test-Path -LiteralPath $runtimeRequirementsPath -PathType Leaf
    if ($hasRuntimeDeclaration -or $hasRuntimeChecker -or $hasRuntimeRequirements) {
        if (-not ($hasRuntimeDeclaration -and $hasRuntimeChecker -and $hasRuntimeRequirements)) {
            throw 'Runtime declaration and checker must be packaged together.'
        }
        $requirements = [IO.File]::ReadAllText($runtimeRequirementsPath) | ConvertFrom-Json
        if (($requirements | ConvertTo-Json -Depth 4 -Compress) -cne
            ($manifest.runtimeRequirements | ConvertTo-Json -Depth 4 -Compress)) {
            throw 'Runtime requirements differ from the build manifest.'
        }
        $runtimeJson = & $systemPowerShell -NoProfile -ExecutionPolicy Bypass -File $runtimeChecker -PackageDirectory $package -AsJson
        $runtimeExit = $LASTEXITCODE
        $runtimeStatus = ($runtimeJson -join "`n") | ConvertFrom-Json
        $report['runtime'] = $runtimeStatus
        if ($runtimeExit -ne 0 -or $runtimeStatus.passed -ne $true) { throw 'Packaged runtime preflight failed.' }
        $report.checks += [ordered]@{name = 'declared_x64_runtime_preflight'; passed = $true}
    }
    if (Test-Path -LiteralPath (Join-Path $package 'powershell.exe')) { throw 'Packaged executable would shadow system Windows PowerShell.' }
    $cmdText = [IO.File]::ReadAllText($launcher)
    if ($cmdText -notmatch '(?im)^powershell\.exe\s+-NoProfile\s+-ExecutionPolicy\s+Bypass\s+-File\s+"%~dp0Start-HanMusic\.ps1"\s*$') {
        throw 'CMD launcher does not invoke the expected packaged PowerShell script.'
    }
    $previousIds = @(Get-Process -Name han_music -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $launchTime = [DateTime]::UtcNow
    $originalPath = $env:Path
    try {
        # The actual CMD wrapper is run by its Windows association; no cmd /c
        # command string is assembled. Pin the system engine ahead of PATH shims.
        $env:Path = (Split-Path -Parent $systemPowerShell) + ';' + $originalPath
        $helper = Start-Process -FilePath $launcher -WindowStyle Hidden -PassThru -WorkingDirectory $package
    } finally { $env:Path = $originalPath }
    if ($null -eq $helper) { throw 'Windows did not return a CMD wrapper process handle.' }
    $helperExecutable = [IO.Path]::GetFullPath($helper.Path)
    $helperStartTicks = $helper.StartTime.ToUniversalTime().Ticks
    $report.launcherPowerShell = [ordered]@{executable = $systemPowerShell; productVersion = (Get-Item -LiteralPath $systemPowerShell).VersionInfo.ProductVersion;
        userEntryPoint = 'Start-HanMusic.cmd'; wrapperExecutable = $helperExecutable; wrapperProcessId = $helper.Id;
        systemEnginePinnedInChildPath = $true; windowStyle = 'Hidden'; defaultDataDirectory = $true}
    $startup = [Diagnostics.Stopwatch]::StartNew()
    while ($null -eq $ownedApp -and $startup.Elapsed.TotalSeconds -lt 20) {
        $appCandidates = @(Get-MatchingApp -Executable $appExecutable -LaunchedAt $launchTime -PreviousIds $previousIds)
        if ($appCandidates.Count -gt 1) { throw 'Launcher created more than one matching app process.' }
        if ($appCandidates.Count -eq 1) { $ownedApp = $appCandidates[0]; $appStartTicks = $ownedApp.StartTime.ToUniversalTime().Ticks; break }
        $helper.Refresh()
        if ($helper.HasExited -and $helper.ExitCode -ne 0) { throw 'Packaged launcher returned a failure exit code.' }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $ownedApp) { throw 'No new child process with the exact extracted executable path appeared within 20 seconds.' }
    $observation = [Diagnostics.Stopwatch]::StartNew()
    $observations = @()
    while ($observation.Elapsed.TotalSeconds -lt 8) {
        $ownedApp.Refresh()
        if ($ownedApp.HasExited) { throw 'Application exited during the eight-second observation.' }
        $observations += [ordered]@{elapsedMs = $observation.ElapsedMilliseconds; responding = $ownedApp.Responding}
        Start-Sleep -Milliseconds 250
    }
    $ownedApp.Refresh()
    if ($ownedApp.HasExited -or -not $ownedApp.Responding -or @($observations | Where-Object { -not $_.responding }).Count -gt 0) {
        throw 'Application did not stay alive and responding for the observation window.'
    }
    $dataDirectory = Join-Path $package 'UserData'
    $onlineDirectory = Join-Path $dataDirectory 'online'
    if (-not (Test-Path -LiteralPath $dataDirectory -PathType Container) -or
        -not (Test-Path -LiteralPath $onlineDirectory -PathType Container)) { throw 'Default UserData and online directories were not created.' }
    if (-not $helper.WaitForExit(3000) -or $helper.ExitCode -ne 0) { throw 'Packaged launcher did not complete successfully.' }
    $nativeApp = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $ownedApp.Id)
    $report.smoke = [ordered]@{processId = $ownedApp.Id; executable = $appExecutable; parentProcessId = $nativeApp.ParentProcessId;
        ownership = 'New PID after launcher start, exact EXE inside this run unique extraction directory, and rechecked process start time';
        elapsedMs = $observation.ElapsedMilliseconds; alive = $true; responding = $true; samples = $observations;
        userDataDirectoryCreated = $true; onlineDirectoryCreated = $true; launcherExitCode = $helper.ExitCode;
        normalCloseTested = $false; guiInteractionTested = $false; cleanMachineTested = $false}
    $report.checks += [ordered]@{name = 'stock_windows_powershell_launcher_eight_second_smoke'; passed = $true}
    if ($CheckDataDirectoryLock) {
        $lockProbePath = Join-Path $dataDirectory '.hanmusic.lock'
        Assert-NoLinkedAncestors -Value $lockProbePath
        if (-not (Test-Path -LiteralPath $lockProbePath -PathType Leaf)) {
            throw 'Application did not create the expected UserData lock file.'
        }
        $report.dataDirectoryLock.path = $lockProbePath
        $lockCheckAttempted = $true
        $lockResult = Test-DataDirectoryLockRange -LockFile $lockProbePath
        $report.dataDirectoryLock.heldWhileRunning = -not $lockResult.acquired
        $report.dataDirectoryLock.conflictWin32Error = $lockResult.win32Error
        $report.dataDirectoryLock.conflictHResult = $lockResult.hResult
        if ($lockResult.acquired) { throw 'Running application does not hold the data directory lock.' }
        $report.checks += [ordered]@{name = 'running_app_holds_data_directory_lock'; passed = $true; win32Error = 33}
        $report.limitations += 'File-range conflict and post-termination release do not replace a second-instance UI check.'
    }
    $report.passed = $true
} catch {
    $report.error = $_.Exception.Message
} finally {
    # Recheck PID, full image path and start time before forcing termination.
    # Nothing is deleted; archives, extracted packages, UserData and logs remain.
    if ($null -ne $helper -and $null -eq $ownedApp -and $null -ne $appExecutable -and $null -ne $launchTime) {
        $late = @(Get-MatchingApp -Executable $appExecutable -LaunchedAt $launchTime -PreviousIds $previousIds)
        if ($late.Count -eq 1) { $ownedApp = $late[0]; $appStartTicks = $ownedApp.StartTime.ToUniversalTime().Ticks }
    }
    if ($null -ne $ownedApp) {
        $report.cleanup.appStopped = Stop-ExactOwnedProcess -Id $ownedApp.Id -Executable $appExecutable -StartTicks $appStartTicks
        if (-not $report.cleanup.appStopped) { $report.passed = $false; $report.error = 'Could not stop the exact owned app process safely.' }
    }
    if ($null -ne $helper) {
        $report.cleanup.helperStopped = Stop-ExactOwnedProcess -Id $helper.Id -Executable $helperExecutable -StartTicks $helperStartTicks
        if (-not $report.cleanup.helperStopped) { $report.passed = $false; $report.error = 'Could not stop the exact owned helper process safely.' }
    }
    if ($CheckDataDirectoryLock -and $lockCheckAttempted -and $report.cleanup.appStopped -eq $true) {
        $releaseTimer = [Diagnostics.Stopwatch]::StartNew()
        try {
            $report.dataDirectoryLock.releasedAfterStop = $false
            while ($releaseTimer.ElapsedMilliseconds -lt 5000) {
                Assert-NoLinkedAncestors -Value $lockProbePath
                $report.dataDirectoryLock.releaseAttempts++
                $released = Test-DataDirectoryLockRange -LockFile $lockProbePath
                if ($released.acquired) {
                    $report.dataDirectoryLock.releasedAfterStop = $true
                    break
                }
                # Only error 33 reaches this retry; missing files, permissions,
                # sharing violations and all other errors fail immediately.
                $remainingMs = 5000 - $releaseTimer.ElapsedMilliseconds
                if ($remainingMs -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min(100, $remainingMs)) }
            }
            if (-not $report.dataDirectoryLock.releasedAfterStop) {
                throw 'Data directory lock was not released within five seconds after stopping the owned app.'
            }
            $report.checks += [ordered]@{name = 'data_directory_lock_released_after_owned_app_stop'; passed = $true}
        } catch {
            $report.passed = $false
            $releaseError = 'Data directory lock release check failed: ' + $_.Exception.Message
            $report.dataDirectoryLock.releaseError = $releaseError
            if ($report.error) { $report.error += ' ' + $releaseError } else { $report.error = $releaseError }
        } finally {
            $report.dataDirectoryLock.releaseWaitMs = $releaseTimer.ElapsedMilliseconds
        }
    }
    $report['finishedAt'] = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 10), $utf8)
}
[ordered]@{reportPath = $reportPath; passed = $report.passed} | ConvertTo-Json -Compress
if ($report.passed) { exit 0 } else { exit 1 }
