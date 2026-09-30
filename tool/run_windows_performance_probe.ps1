<#
.SYNOPSIS
Runs one fresh, unprofiled-by-this-wrapper Windows Profile performance capture.
.DESCRIPTION
Build the bundle separately with --profile -t tool/windows_m5_performance_probe.dart
and --dart-define=HANMUSIC_PROBE_DIR=<ProbeDirectory>. The output location is a
Dart compile-time constant: an environment variable cannot redirect this probe.
Freeze the entire baseline bundle before building a candidate. Run A/B serially
with unique RunName values and the same ProbeDirectory, display and workload.
Do not attach DevTools/CPU collectors or run builds/tests during these captures.

The caller is responsible for the selected bundle's entry point and compile
constant. This script validates the resulting capture, not the performance goal.
It never starts a VM Service client, changes profiler flags, or kills another
HanMusic process. Existing fixed-name probe outputs are archived before launch.

Example (after building the matching diagnostic):
  powershell.exe -NoProfile -File tool/run_windows_performance_probe.ps1 `
    -BundleDirectory D:/dev/tmp/hanmusic-performance-ab/dev7-baseline `
    -EvidenceDirectory D:/dev/setup/verification/m5-performance-ab -RunName a1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BundleDirectory,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
    [Parameter(Mandatory=$true)][string]$RunName,
    [string]$ProbeDirectory = 'D:\dev\tmp\hanmusic-m5-performance'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'windows_packaging_utils.ps1')
$invariant = [Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object Text.UTF8Encoding($false)

function Get-AbsoluteDPath {
    param([string]$Value)
    if ($Value -notmatch '^[dD]:[\\/]' -or $Value.Substring(2).Contains(':') -or
        @($Value.Split([char[]]'\/') | Where-Object { $_ -eq '..' -or $_.EndsWith(' ') -or $_.EndsWith('.') }).Count) {
        throw 'All directories must be explicit absolute D: paths without traversal or alternate streams.'
    }
    $normalized = [IO.Path]::GetFullPath($Value).TrimEnd([char]'\')
    if ($normalized -eq 'D:') { throw 'A drive root is not a diagnostic directory.' }
    return $normalized
}

function Assert-NoLinkedAncestors {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Evidence/probe paths cannot traverse a reparse point: $cursor"
        }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd([char]'\'))
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Test-Within {
    param([string]$Candidate, [string]$Root)
    return $Candidate.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or
        $Candidate.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-CpuObservation {
    $counter = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
    if ($null -eq $counter) { throw 'Unable to read the system CPU counter.' }
    return [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); totalPercent = [double]$counter.PercentProcessorTime }
}

function Assert-NoCpuCollector {
    # This is a useful known-client check, not a claim that every external
    # debugger can be detected. No VM Service RPC is used in a clean capture.
    $clients = @(Get-CimInstance Win32_Process -Filter "Name='dart.exe' OR Name='dartaotruntime.exe'" |
        Where-Object { $_.CommandLine -match 'collect_m5_cpu_samples(?:\.dart)?' })
    if ($clients.Count) { throw 'The M5 CPU collector is running; use a separate diagnostic run.' }
}

function Get-BundleHashes {
    param([string]$Root)
    $hashes = [ordered]@{}
    foreach ($relative in @('han_music.exe', 'data\app.so', 'flutter_windows.dll')) {
        $file = Join-Path $Root $relative
        $item = Get-Item -LiteralPath $file -Force
        $hashes[$relative] = [ordered]@{
            bytes = $item.Length
            sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
            lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        }
    }
    return $hashes
}

function Copy-NewFile {
    param([string]$Source, [string]$Destination)
    Assert-NoLinkedAncestors $Source
    Assert-NoLinkedAncestors $Destination
    $inputFile = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sourceWriteUtc = [IO.File]::GetLastWriteTimeUtc($Source)
        $outputFile = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $inputFile.CopyTo($outputFile); $outputFile.Flush() } finally { $outputFile.Dispose() }
        # Freshness belongs to the probe's write, not later hash/CPU sampling
        # and archive-copy work performed after process exit.
        [IO.File]::SetLastWriteTimeUtc($Destination, $sourceWriteUtc)
    } finally { $inputFile.Dispose() }
}

function Get-FiniteNumber {
    param($Value, [string]$Name)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { throw "Invalid numeric field: $Name" }
    $number = [Convert]::ToDouble($Value, $invariant)
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) {
        throw "Invalid nonnegative finite field: $Name"
    }
    return $number
}

function Assert-Near {
    param($Actual, [double]$Expected, [string]$Name)
    $number = Get-FiniteNumber $Actual $Name
    if ([math]::Abs($number - $Expected) -gt 0.00000001) { throw "CSV/JSON mismatch: $Name" }
}

function Get-CsvInteger {
    param([string]$Value, [string]$Name)
    $number = [long]0
    if (-not [long]::TryParse($Value, [Globalization.NumberStyles]::None, $invariant, [ref]$number) -or $number -lt 0) {
        throw "Invalid unsigned integer CSV field: $Name"
    }
    return $number
}

function Get-NearestRank95 {
    param([long[]]$Values)
    $sorted = [long[]]$Values.Clone()
    [Array]::Sort($sorted)
    return $sorted[[int][math]::Ceiling($sorted.Length * 0.95) - 1] / 1000.0
}

function Test-CaptureEvidence {
    param([string]$JsonPath, [string]$CsvPath, [DateTime]$Launched, [DateTime]$Ended)
    foreach ($file in @($JsonPath, $CsvPath)) {
        Assert-NoLinkedAncestors $file
        $info = Get-Item -LiteralPath $file -Force
        if ($info.PSIsContainer -or $info.Length -eq 0 -or $info.Length -gt 67108864 -or
            $info.LastWriteTimeUtc -lt $Launched -or $info.LastWriteTimeUtc -gt $Ended.AddSeconds(1)) {
            throw 'Probe result is missing, too large, stale or outside this launch interval.'
        }
    }
    $result = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $reportStarted = [DateTimeOffset]::Parse($result.startedAtUtc, $invariant, [Globalization.DateTimeStyles]::None)
    if ($reportStarted.Offset -ne [TimeSpan]::Zero -or $reportStarted.UtcDateTime -lt $Launched -or $reportStarted.UtcDateTime -gt $Ended) {
        throw 'JSON startedAtUtc does not belong to this launch interval.'
    }
    if ($result.schemaVersion -ne 1 -or $result.completed -ne $true -or $result.buildMode -ne 'profile' -or
        $result.dataset.songs -ne 10000 -or $result.dataset.synthetic -ne $true -or $result.dataset.artwork -ne $false -or
        $result.dataset.seed -ne 'index-0-through-9999-v1' -or
        $result.sampling.requestedWarmupSeconds -ne 5 -or $result.sampling.requestedMeasurementSeconds -ne 30 -or
        $result.sampling.frameTimingBatchDrainMs -ne 1000 -or $result.scroll.oneWaySeconds -ne 10 -or
        @($result.frameworkErrors).Count -ne 0 -or $result.environment.metricsChangesDuringMeasurement -ne 0 -or
        @($result.environment.lifecycleEvents).Count -ne 0 -or $result.environment.textScale -ne 1) {
        throw 'Probe workload, mode, lifecycle, metrics or framework-error validation failed.'
    }
    $seconds = Get-FiniteNumber $result.sampling.actualMeasurementSeconds 'actualMeasurementSeconds'
    if ($seconds -lt 30 -or $seconds -gt 32) { throw 'The sample did not cover a stable 30-second window (allowed 30..32 s).' }
    foreach ($name in @('logicalWidth', 'logicalHeight', 'devicePixelRatio', 'displayRefreshRateHz')) {
        if ((Get-FiniteNumber $result.environment.$name $name) -le 0) { throw "Missing positive environment metric: $name" }
    }
    if ((Get-FiniteNumber $result.sampling.scrollTicks 'scrollTicks') -le 0 -or
        (Get-FiniteNumber $result.scroll.maximumExtentLogicalPx 'maximumExtentLogicalPx') -le 0 -or
        (Get-FiniteNumber $result.scroll.distanceLogicalPx 'distanceLogicalPx') -le 0 -or
        (Get-FiniteNumber $result.scroll.directionChanges 'directionChanges') -lt 2) {
        throw 'The intended repeated scroll workload did not occur.'
    }
    $header = Get-Content -LiteralPath $CsvPath -TotalCount 1 -Encoding UTF8
    if ($header -ne 'frame,vsync_us,ui_us,raster_us,total_us') { throw 'Unexpected frame CSV columns.' }
    $rows = @(Import-Csv -LiteralPath $CsvPath -Encoding UTF8)
    if ($rows.Count -eq 0 -or $rows.Count -ne $result.sampling.frames) { throw 'CSV/JSON frame count mismatch.' }
    $ui = New-Object 'System.Collections.Generic.List[long]'
    $raster = New-Object 'System.Collections.Generic.List[long]'
    $total = New-Object 'System.Collections.Generic.List[long]'
    $previousFrame = [long]-1
    $previousVsync = [long]-1
    $firstVsync = [long]0
    $firstFrame = [long]0
    $refresh = Get-FiniteNumber $result.environment.displayRefreshRateHz 'displayRefreshRateHz'
    $budgets = @{
        fixed60Hz = [ordered]@{ budgetUs = 1000000.0 / 60; uiFrames = 0; rasterFrames = 0; eitherFrames = 0 }
        displayBudget = [ordered]@{ budgetUs = 1000000.0 / $refresh; uiFrames = 0; rasterFrames = 0; eitherFrames = 0 }
    }
    foreach ($row in $rows) {
        $frame = Get-CsvInteger $row.frame 'frame'
        $vsync = Get-CsvInteger $row.vsync_us 'vsync_us'
        $build = Get-CsvInteger $row.ui_us 'ui_us'
        $paint = Get-CsvInteger $row.raster_us 'raster_us'
        $span = Get-CsvInteger $row.total_us 'total_us'
        if ($frame -le $previousFrame -or $vsync -le $previousVsync -or $span -lt [math]::Max($build, $paint)) {
            throw 'CSV frame numbers/timestamps are not strictly ordered and unique, or durations are inconsistent.'
        }
        if ($ui.Count -eq 0) { $firstVsync = $vsync; $firstFrame = $frame }
        $previousFrame = $frame
        $previousVsync = $vsync
        $ui.Add($build); $raster.Add($paint); $total.Add($span)
        foreach ($key in $budgets.Keys) {
            $budget = $budgets[$key]
            $slowUi = $build -gt $budget.budgetUs
            $slowRaster = $paint -gt $budget.budgetUs
            if ($slowUi) { $budget.uiFrames++ }
            if ($slowRaster) { $budget.rasterFrames++ }
            if ($slowUi -or $slowRaster) { $budget.eitherFrames++ }
        }
    }
    $csvSpan = ($previousVsync - $firstVsync) / 1000000.0
    if ([math]::Abs($csvSpan - $seconds) -gt 1) { throw 'Frame timestamps do not cover the reported measurement interval.' }
    $p95 = [ordered]@{
        ui = Get-NearestRank95 $ui.ToArray()
        raster = Get-NearestRank95 $raster.ToArray()
        totalSpan = Get-NearestRank95 $total.ToArray()
    }
    foreach ($key in $p95.Keys) { Assert-Near $result.timingsMs.$key.p95 $p95[$key] "timingsMs.$key.p95" }
    Assert-Near $result.sampling.sampledFramesPerSecond ($rows.Count / $seconds) 'sampledFramesPerSecond'
    Assert-Near $result.jank.displayBudgetMs (1000.0 / $refresh) 'displayBudgetMs'
    foreach ($key in $budgets.Keys) {
        $budget = $budgets[$key]
        $budget['eitherPercent'] = 100.0 * $budget.eitherFrames / $rows.Count
        foreach ($field in @('uiFrames', 'rasterFrames', 'eitherFrames', 'eitherPercent')) {
            Assert-Near $result.jank.$key.$field $budget[$field] "jank.$key.$field"
        }
    }
    return [ordered]@{
        validCapture = $true
        reportStartedAtUtc = $reportStarted.UtcDateTime.ToString('o')
        dataset = $result.dataset
        environment = $result.environment
        sampling = $result.sampling
        scroll = $result.scroll
        memory = $result.memory
        recalculated = [ordered]@{
            frameCount = $rows.Count; firstFrame = $firstFrame; lastFrame = $previousFrame
            frameNumbersAndVsyncStrictlyIncreasing = $true; csvVsyncSpanSeconds = $csvSpan
            p95NearestRankMs = $p95; overBudget = $budgets
        }
        performanceThresholdVerdict = 'Not evaluated. Valid capture is not a performance pass; compare identical A/B workloads separately.'
    }
}

# Finish all read-only input/output checks before creating evidence or launching.
if ($RunName -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'RunName must contain 1..64 lowercase letters/digits/hyphens and start with a letter/digit.' }
$bundleInput = Get-AbsoluteDPath $BundleDirectory
$evidence = Get-AbsoluteDPath $EvidenceDirectory
$probe = Get-AbsoluteDPath $ProbeDirectory
if (-not (Test-Path -LiteralPath $bundleInput -PathType Container)) { throw 'BundleDirectory must already exist.' }
$bundle = Get-AbsoluteDPath (Get-HanMusicPhysicalPath $bundleInput)
Assert-HanMusicNoReparseTree $bundle
Assert-NoLinkedAncestors $evidence
Assert-NoLinkedAncestors $probe
if ((Test-Within $evidence $bundle) -or (Test-Within $bundle $evidence) -or
    (Test-Within $probe $bundle) -or (Test-Within $bundle $probe) -or
    (Test-Within $evidence $probe) -or (Test-Within $probe $evidence)) {
    throw 'Bundle, evidence and probe directories must be separate, non-overlapping directories.'
}
foreach ($directory in @($evidence, $probe)) {
    $existing = Get-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
    if ($existing -and -not $existing.PSIsContainer) { throw 'An output directory path names a file.' }
}
$exe = Join-Path $bundle 'han_music.exe'
foreach ($relative in @('han_music.exe', 'data\app.so', 'flutter_windows.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundle $relative) -PathType Leaf)) { throw "Missing Profile bundle file: $relative" }
}
$prefix = Join-Path $evidence $RunName
$outputs = @("$prefix.json", "$prefix.frames.csv", "$prefix.session.json", "$prefix.stdout.txt", "$prefix.stderr.txt",
    "$prefix.previous-probe.json", "$prefix.previous-probe.frames.csv")
foreach ($output in $outputs) {
    Assert-NoLinkedAncestors $output
    if (Get-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue) { throw "Run evidence already exists: $output" }
}
$fixedJson = Join-Path $probe 'result-m5-performance.json'
$fixedCsv = Join-Path $probe 'frames-m5-performance.csv'
$probeLockPath = Join-Path $probe '.hanmusic-performance-wrapper.lock'
foreach ($file in @($fixedJson, $fixedCsv, $probeLockPath)) {
    Assert-NoLinkedAncestors $file
    $existing = Get-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if ($existing -and $existing.PSIsContainer) { throw 'A fixed probe output path names a directory.' }
}
if (@(Get-Process -Name han_music -ErrorAction SilentlyContinue).Count) { throw 'Another HanMusic process is running; leave it untouched and measure later.' }
Assert-NoCpuCollector
$hashesBefore = Get-BundleHashes $bundle
$cpuBefore = Get-CpuObservation

$metadata = [ordered]@{
    schemaVersion = 1; runName = $RunName; diagnosticRun = $false
    bundleDirectory = $bundle; bundleInput = $bundleInput; executable = $exe
    fileVersion = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
    evidenceDirectory = $evidence; probeDirectoryExpectedCompileConstant = $probe
    entryPointExpected = 'tool/windows_m5_performance_probe.dart'
    startedAtUtc = [DateTime]::UtcNow.ToString('o'); timeoutSeconds = 120
    cpuBefore = $cpuBefore; hashesBefore = $hashesBefore
    cpuProfilerStartedByWrapper = $false
    profilerCondition = 'Known collector absent before/after; no VM Service connection by wrapper. Operator must prevent external profiler attachment.'
    scratchDirectoryLock = $probeLockPath
    validCapture = $false; forcedTermination = $false; preservedPreviousProbeOutputs = @()
}
$process = $null
$sessionHandle = $null
$probeLockHandle = $null
$processWatch = $null
try {
    $null = [IO.Directory]::CreateDirectory($evidence)
    $null = [IO.Directory]::CreateDirectory($probe)
    # FileShare.None prevents two wrappers from racing over the shared fixed
    # probe outputs. Keep the marker; closing/crashing releases its OS handle.
    Assert-NoLinkedAncestors $probeLockPath
    $probeLockHandle = [IO.File]::Open($probeLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    # Reserve this run identity with CreateNew and retain the handle for final
    # metadata. A competing wrapper with the same name fails before launch.
    $sessionHandle = [IO.File]::Open("$prefix.session.json", [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    foreach ($pair in @(@($fixedJson, "$prefix.previous-probe.json"), @($fixedCsv, "$prefix.previous-probe.frames.csv"))) {
        if (Test-Path -LiteralPath $pair[0] -PathType Leaf) {
            Copy-NewFile $pair[0] $pair[1]
            $metadata.preservedPreviousProbeOutputs += [ordered]@{
                source = $pair[0]; archive = $pair[1]
                sourceLastWriteTimeUtc = [IO.File]::GetLastWriteTimeUtc($pair[0]).ToString('o')
                sha256 = (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    }
    $launched = [DateTime]::UtcNow
    $metadata.launchedAtUtc = $launched.ToString('o')
    $processWatch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $exe -WorkingDirectory $bundle -WindowStyle Hidden -PassThru -RedirectStandardOutput "$prefix.stdout.txt" -RedirectStandardError "$prefix.stderr.txt"
    $null = $process.Handle # Retain before waiting: required for reliable PS5.1 ExitCode.
    $metadata.processId = $process.Id
    $metadata.processStartTicks = $process.StartTime.ToUniversalTime().Ticks
    while (-not $process.WaitForExit(250)) {
        if ($processWatch.Elapsed.TotalSeconds -ge 120) { throw 'Profile probe exceeded its 120-second deadline.' }
    }
    $ended = [DateTime]::UtcNow
    $metadata.processWallMs = $processWatch.ElapsedMilliseconds
    $metadata.endedAtUtc = $ended.ToString('o')
    $exitValue = $process.ExitCode
    $metadata.exitCode = $exitValue
    if ($null -eq $exitValue) { throw 'Process exit code is unavailable; this cannot be a successful capture.' }
    $metadata.cpuAfter = Get-CpuObservation
    $metadata.hashesAfter = Get-BundleHashes $bundle
    foreach ($key in $hashesBefore.Keys) {
        if ($metadata.hashesAfter[$key].sha256 -ne $hashesBefore[$key].sha256) { throw 'The Profile bundle changed during the run.' }
    }
    Assert-NoCpuCollector
    if (@(Get-Process -Name han_music -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $process.Id }).Count) {
        throw 'Another HanMusic process appeared during this capture; it was not stopped.'
    }
    # Preserve raw fresh artifacts even if their exit code or JSON validation
    # fails. Never present a stale fixed-name file as this run's new result.
    foreach ($pair in @(@($fixedJson, "$prefix.json"), @($fixedCsv, "$prefix.frames.csv"))) {
        $item = Get-Item -LiteralPath $pair[0] -Force -ErrorAction SilentlyContinue
        if ($item -and -not $item.PSIsContainer -and $item.LastWriteTimeUtc -ge $launched) { Copy-NewFile $pair[0] $pair[1] }
    }
    $metadata.sourceOutputMetadata = @($fixedJson, $fixedCsv) | ForEach-Object {
        $item = Get-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue
        if ($item) { [ordered]@{ path = $_; bytes = $item.Length; lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o') } }
    }
    if ($exitValue -ne 0) { throw "Profile process failed with exit code $exitValue; inspect preserved evidence." }
    $metadata.validation = Test-CaptureEvidence "$prefix.json" "$prefix.frames.csv" $launched $ended
    $metadata.validCapture = $true
} catch {
    $metadata.failure = $_.Exception.Message
    throw
} finally {
    try {
        if ($process -and -not $process.HasExited) {
            try {
                $live = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
                if ($live -and $metadata.Contains('processStartTicks') -and
                    $live.StartTime.ToUniversalTime().Ticks -eq $metadata.processStartTicks -and
                    (Get-HanMusicPhysicalPath $live.Path) -ieq $exe) {
                    Stop-Process -InputObject $live -Force
                    $metadata.forcedTermination = $true
                    $metadata.stoppedAfterTimeout = $process.WaitForExit(5000)
                    if (-not $metadata.stoppedAfterTimeout) { $metadata.cleanupError = 'Owned process did not exit after termination.' }
                } else { $metadata.cleanupError = 'PID/start-time/path identity not confirmed; no unrelated process was stopped.' }
            } catch { $metadata.cleanupError = $_.Exception.Message }
        }
    } finally {
        $metadata.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
        if ($sessionHandle) {
            try {
                $json = $metadata | ConvertTo-Json -Depth 16
                $bytes = $utf8.GetBytes($json)
                $sessionHandle.Write($bytes, 0, $bytes.Length)
                $sessionHandle.Flush()
            } finally { $sessionHandle.Dispose() }
        }
        if ($process) { $process.Dispose() }
        if ($probeLockHandle) { $probeLockHandle.Dispose() }
    }
}
$metadata | ConvertTo-Json -Depth 16
