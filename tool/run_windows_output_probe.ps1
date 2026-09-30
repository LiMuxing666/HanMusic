[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunDirectory,
    [Parameter(Mandatory = $true)][ValidateSet('all', 'cold-network')][string]$Phase,
    [string]$ProjectDirectory = 'D:\project\HanMusic',
    [ValidateRange(30, 240)][int]$TimeoutSeconds = 200
)

# Run only the separately built diagnostic entry point, never a user's session.
# First build -t tool/windows_m5_output_probe.dart; restore lib/main.dart afterward.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-NoLinkedAncestors {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Probe paths must not traverse links or junctions.'
        }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd([char]'\'))
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

if ($RunDirectory -notmatch '^[dD]:[\\/]dev[\\/]tmp[\\/]hanmusic-m5-output-[A-Za-z0-9_-]+[\\/]?$') {
    throw 'RunDirectory must be a dedicated D:\dev\tmp\hanmusic-m5-output-<id> directory.'
}
$runRoot = [IO.Path]::GetFullPath($RunDirectory).TrimEnd([char]'\')
Assert-NoLinkedAncestors $runRoot
if (-not (Test-Path -LiteralPath $runRoot -PathType Container)) { throw 'Create the run directory first.' }
if ($ProjectDirectory -notmatch '^[dD]:[\\/]') { throw 'ProjectDirectory must be an absolute D: path.' }
$project = [IO.Path]::GetFullPath($ProjectDirectory)
$bundle = Join-Path $project 'build\windows\x64\runner\Release'
$exe = Join-Path $bundle 'han_music.exe'
$appSo = Join-Path $bundle 'data\app.so'
$dll = Join-Path $runRoot 'native\process_loopback_probe.dll'
Assert-NoLinkedAncestors $dll
foreach ($required in @($exe, $appSo, $dll)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing diagnostic artifact: $required" }
}
$prefix = Join-Path $runRoot "output-$Phase"
$resultPath = Join-Path $runRoot "result-output-$Phase.json"
$dataPath = Join-Path $runRoot 'data'
Assert-NoLinkedAncestors $dataPath
foreach ($output in @($resultPath, "$prefix.stdout.txt", "$prefix.stderr.txt", "$prefix.session.json")) {
    Assert-NoLinkedAncestors $output
    if (Get-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue) { throw 'Run evidence already exists; choose a fresh run directory.' }
}

$environment = @{
    HANMUSIC_PROBE_DIR = $runRoot
    HANMUSIC_PROBE_PHASE = $Phase
    HANMUSIC_LOOPBACK_DLL = $dll
    HANMUSIC_DATA_DIR = $dataPath
    TEMP = 'D:\dev\tmp'
    TMP = 'D:\dev\tmp'
}
$previousEnvironment = @{}
$metadata = [ordered]@{
    schemaVersion = 1
    phase = $Phase
    runDirectory = $runRoot
    executable = $exe
    entryPointExpected = 'tool/windows_m5_output_probe.dart'
    appSoSha256 = (Get-FileHash -LiteralPath $appSo -Algorithm SHA256).Hash.ToLowerInvariant()
    dllSha256 = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant()
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    timeoutSeconds = $TimeoutSeconds
    forcedTermination = $false
    passed = $false
}
$proc = $null
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    foreach ($key in $environment.Keys) {
        $previousEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $environment[$key], 'Process')
    }
    $proc = Start-Process -FilePath $exe -WorkingDirectory $bundle -WindowStyle Hidden -PassThru -RedirectStandardOutput "$prefix.stdout.txt" -RedirectStandardError "$prefix.stderr.txt"
    # Retain the process handle before waiting; Windows PowerShell 5.1 can
    # otherwise lose the native exit code once a short-lived process exits.
    $null = $proc.Handle
    $metadata.processId = $proc.Id
    $metadata.processStartTicks = $proc.StartTime.ToUniversalTime().Ticks
    while (-not $proc.WaitForExit(500)) {
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'Diagnostic process exceeded its outer timeout.' }
    }
    $proc.WaitForExit()
    $metadata.exitCode = $proc.ExitCode
    Assert-NoLinkedAncestors $resultPath
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'Diagnostic process did not produce its expected report.' }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if ($result.phase -ne $Phase -or $result.pid -ne $proc.Id) { throw 'Report does not belong to this diagnostic process.' }
    if ($proc.ExitCode -ne 0 -or $result.passed -ne $true) { throw 'Audio output probe failed; inspect the preserved report.' }
    $metadata.passed = $true
} catch {
    $metadata.failure = $_.Exception.Message
    throw
} finally {
    try {
        if ($proc -and -not $proc.HasExited) {
            $live = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
            if ($live -and $live.StartTime.ToUniversalTime().Ticks -eq $metadata.processStartTicks -and $live.Path -ieq $exe) {
                Stop-Process -InputObject $live -Force
                $metadata.forcedTermination = $true
                $metadata.stopped = $proc.WaitForExit(5000)
            } else {
                $metadata.cleanupError = 'Process identity could not be confirmed; no unrelated process was stopped.'
            }
        }
    } finally {
        foreach ($key in $previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $previousEnvironment[$key], 'Process')
        }
        $metadata.processWallMs = $watch.ElapsedMilliseconds
        $metadata.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
        Assert-NoLinkedAncestors "$prefix.session.json"
        $json = $metadata | ConvertTo-Json -Depth 6
        $stream = [IO.File]::Open("$prefix.session.json", [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
    }
}
$metadata | ConvertTo-Json -Depth 6
