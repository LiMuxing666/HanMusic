param([string]$EvidenceDirectory = ('D:\dev\tmp\hanmusic-environment-test-' + [guid]::NewGuid().ToString('N')))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
if ($evidence -notmatch '^[dD]:[\\/]' -or $EvidenceDirectory -notmatch '^[dD]:[\\/]') { throw 'An absolute D-drive evidence directory is required.' }
if (Get-Item -LiteralPath $evidence -Force -ErrorAction SilentlyContinue) { throw 'Refusing to overwrite test evidence.' }
$ancestor = [IO.DirectoryInfo]$evidence
while ($null -ne $ancestor) {
    $item = Get-Item -LiteralPath $ancestor.FullName -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked evidence paths are not allowed.' }
    $ancestor = $ancestor.Parent
}
[void][IO.Directory]::CreateDirectory($evidence)
$results = New-Object 'System.Collections.Generic.List[object]'
$helper = Join-Path $PSScriptRoot 'windows_performance_environment.ps1'
function Assert-EnvironmentTest { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Invoke-EnvironmentTest {
    param([string]$Name,[scriptblock]$Body)
    try { & $Body; $results.Add([pscustomobject]@{name=$Name;passed=$true}) }
    catch { $results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message}) }
}

$parseTokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($helper,[ref]$parseTokens,[ref]$parseErrors)
Invoke-EnvironmentTest 'PS parser accepts helper' { Assert-EnvironmentTest ($parseErrors.Count -eq 0) 'Helper contains parser errors.' }
$dotSourceOutput = @(. $helper)
Invoke-EnvironmentTest 'dot source is silent' { Assert-EnvironmentTest ($dotSourceOutput.Count -eq 0) 'Dot-sourcing emitted output.' }

$collector = $null
$missing = $null
$partial = $null
$selfProcess = Get-Process -Id $PID
try {
    $collector = Start-HanMusicPerformanceEnvironment
    $prewarm = Read-HanMusicPerformanceEnvironment -Collector $collector -TargetProcess $selfProcess
    Start-Sleep -Milliseconds 1100
    $sample = Read-HanMusicPerformanceEnvironment -Collector $collector -TargetProcess $selfProcess
    $sample | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence 'live-sample.json') -Encoding UTF8
    Invoke-EnvironmentTest 'real APIs and exact process QoS are readable' {
        Assert-EnvironmentTest ($null -eq $collector.InitializationError) ('Interop initialization failed: ' + $collector.InitializationError)
        Assert-EnvironmentTest ($sample.power.status -eq 'ok') 'Power API was not readable on this machine.'
        Assert-EnvironmentTest ($sample.memory.status -eq 'ok' -and $sample.memory.totalPhysicalBytes -gt 0) 'Memory API was not readable.'
        Assert-EnvironmentTest ($sample.processQos.status -eq 'ok' -and $sample.processQos.targetProcessId -eq $PID) 'Exact self process QoS query failed.'
        Assert-EnvironmentTest ($sample.durationMs -ge 0 -and $sample.cpu.durationMs -ge 0) 'Observation durations are missing.'
        Assert-EnvironmentTest ($sample.cpu.counters.processorFrequencyMHz.status -eq 'ok') 'The known local frequency counter was not readable.'
        Assert-EnvironmentTest ($sample.cpu.counters.processorPerformancePercent.status -eq 'ok') 'The rate counter did not warm up.'
        $observedUtc = [DateTime]::Parse($sample.cpu.collectedAtUtc).ToUniversalTime()
        Assert-EnvironmentTest ($observedUtc -ge [DateTime]::Parse($sample.startedAtUtc).ToUniversalTime() -and $observedUtc -le [DateTime]::Parse($sample.completedAtUtc).ToUniversalTime()) 'CPU observation UTC falls outside the sample window.'
    }
    $warmSamples = @(1..3 | ForEach-Object { Start-Sleep -Milliseconds 100; Read-HanMusicPerformanceEnvironment -Collector $collector -TargetProcess $selfProcess })
    $warmSamples | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence 'warm-samples.json') -Encoding UTF8
    $missing = Start-HanMusicPerformanceEnvironment -CounterPaths ([ordered]@{ absent='\HanMusic nonexistent counterset 8db741(_Total)\Missing' })
    $missingSample = Read-HanMusicPerformanceEnvironment -Collector $missing
    $missingSample | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence 'unavailable-counter.json') -Encoding UTF8
    Invoke-EnvironmentTest 'missing counter degrades without failing other APIs' {
        Assert-EnvironmentTest ($missingSample.cpu.counters.absent.status -eq 'unavailable') 'Missing counter was reported as valid.'
        Assert-EnvironmentTest ($null -eq $missingSample.cpu.counters.absent.value) 'Missing counter became a fake zero.'
        Assert-EnvironmentTest (-not [string]::IsNullOrEmpty($missingSample.cpu.counters.absent.reason)) 'Missing counter has no reason.'
        Assert-EnvironmentTest ($missingSample.power.status -eq 'ok' -and $missingSample.memory.status -eq 'ok') 'A missing counter broke independent APIs.'
    }
    $partial = Start-HanMusicPerformanceEnvironment -CounterPaths ([ordered]@{
        frequency='\Processor Information(_Total)\Processor Frequency'
        absentInstance='\Processor Information(HanMusicMissingInstance8db741)\Processor Frequency'
    })
    $partialSample = Read-HanMusicPerformanceEnvironment -Collector $partial
    $partialSample | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence 'partial-counters.json') -Encoding UTF8
    Invoke-EnvironmentTest 'successful collection does not hide a missing instance' {
        Assert-EnvironmentTest ($partialSample.cpu.status -eq 'partial') 'Mixed counter validity was not reported.'
        Assert-EnvironmentTest ($partialSample.cpu.counters.frequency.status -eq 'ok') 'Valid sibling counter was lost.'
        Assert-EnvironmentTest ($partialSample.cpu.counters.absentInstance.status -eq 'unavailable' -and $null -eq $partialSample.cpu.counters.absentInstance.value) 'Missing instance became valid zero.'
    }
    Stop-HanMusicPerformanceEnvironment -Collector $collector
    Stop-HanMusicPerformanceEnvironment -Collector $collector
    $stoppedSample = Read-HanMusicPerformanceEnvironment -Collector $collector -TargetProcess $selfProcess
    Invoke-EnvironmentTest 'dispose is idempotent and read is unavailable afterward' {
        Assert-EnvironmentTest ($stoppedSample.cpu.status -eq 'stopped' -and $stoppedSample.processQos.status -eq 'stopped') 'Disposed collector still reports live observations.'
    }
    $selfProcess.Dispose()
    $disposedTarget = Read-HanMusicPerformanceEnvironment -Collector $missing -TargetProcess $selfProcess
    Invoke-EnvironmentTest 'disposed process object never falls back to PID lookup' {
        Assert-EnvironmentTest ($disposedTarget.processQos.status -eq 'unavailable') 'Disposed process handle was treated as queryable.'
        Assert-EnvironmentTest ($disposedTarget.memory.status -eq 'ok') 'Disposed process broke independent memory query.'
    }
} finally {
    if ($null -ne $collector) { Stop-HanMusicPerformanceEnvironment -Collector $collector }
    if ($null -ne $missing) { Stop-HanMusicPerformanceEnvironment -Collector $missing }
    if ($null -ne $partial) { Stop-HanMusicPerformanceEnvironment -Collector $partial }
    $selfProcess.Dispose()
}
$report = [ordered]@{schemaVersion=1;completedAtUtc=[DateTime]::UtcNow.ToString('o');powerShellVersion=$PSVersionTable.PSVersion.ToString();is64BitProcess=[Environment]::Is64BitProcess;tests=@($results.ToArray());passed=(@($results | Where-Object { -not $_.passed }).Count -eq 0)}
$reportPath = Join-Path $evidence 'report.json'
$report | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $reportPath -Encoding UTF8
[pscustomobject]@{report=$reportPath;passed=$report.passed;testCount=$results.Count} | ConvertTo-Json -Compress
if (-not $report.passed) { exit 1 }
