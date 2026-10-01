<#
.SYNOPSIS
Tests accessibility evidence validation against an existing performance capture.
.DESCRIPTION
Windows PowerShell 5.1 compatible. Extracts only named validation functions from
the repository wrapper; never invokes its launcher or changes source evidence.
Writes seven synthetic JSON/CSV cases and results.json to a new D: directory.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
    [Parameter(Mandatory=$true)][string]$RunName,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$invariant = [Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object Text.UTF8Encoding($false)
$wrapper = Join-Path $PSScriptRoot 'run_windows_performance_probe.ps1'

# Parse trusted repository code, not input evidence, and exclude all top-level
# statements (including parameter binding, environment collection and launch).
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Cannot parse the performance wrapper.' }
$names = @('Get-AbsoluteDPath', 'Assert-NoLinkedAncestors', 'Get-FiniteNumber',
    'Assert-Near', 'Get-CsvInteger', 'Get-NearestRank95', 'Test-CaptureEvidence')
$definitions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true))
foreach ($name in $names) {
    $matches = @($definitions | Where-Object { $_.Name -ceq $name })
    if ($matches.Count -ne 1) { throw "Expected exactly one validator function: $name" }
    . ([ScriptBlock]::Create($matches[0].Extent.Text))
}

function Write-NewEvidenceText {
    param([string]$Path, [string]$Text)
    Assert-NoLinkedAncestors $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $utf8.GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } finally { $stream.Dispose() }
}

function Get-SourceHashes {
    param([System.Collections.IDictionary]$Paths)
    $hashes = [ordered]@{}
    foreach ($key in $Paths.Keys) {
        Assert-NoLinkedAncestors $Paths[$key]
        $hashes[$key] = (Get-FileHash -LiteralPath $Paths[$key] -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $hashes
}

# All input/output validation precedes directory or file creation. Output may be
# a new child of the evidence directory, but an existing output is never reused.
if ($RunName -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'RunName must contain 1..64 lowercase letters/digits/hyphens.' }
$evidence = Get-AbsoluteDPath $EvidenceDirectory
$output = Get-AbsoluteDPath $OutputDirectory
Assert-NoLinkedAncestors $evidence
Assert-NoLinkedAncestors $output
if (-not (Test-Path -LiteralPath $evidence -PathType Container)) { throw 'EvidenceDirectory must exist.' }
if (Get-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue) { throw 'OutputDirectory already exists; refusing to overwrite evidence.' }
$prefix = Join-Path $evidence $RunName
$sources = [ordered]@{ json = "$prefix.json"; frames = "$prefix.frames.csv"; session = "$prefix.session.json" }
foreach ($path in $sources.Values) {
    Assert-NoLinkedAncestors $path
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer -or $item.Length -eq 0 -or $item.Length -gt 67108864) { throw "Invalid source evidence file: $path" }
}
$hashesBefore = Get-SourceHashes $sources
$wrapperHash = (Get-FileHash -LiteralPath $wrapper -Algorithm SHA256).Hash.ToLowerInvariant()
$session = Get-Content -LiteralPath $sources.session -Raw -Encoding UTF8 | ConvertFrom-Json
if ($session.validCapture -ne $true -or $session.runName -cne $RunName -or
    $session.exitCode -ne 0 -or $session.forcedTermination -ne $false) {
    throw 'Source session must describe this run and a successful, unforced capture.'
}
$start = [DateTimeOffset]::Parse($session.launchedAtUtc, $invariant).UtcDateTime
$end = [DateTimeOffset]::Parse($session.endedAtUtc, $invariant).UtcDateTime
if ($end -le $start) { throw 'Source session launch/exit interval is invalid.' }
$sourceValidation = Test-CaptureEvidence $sources.json $sources.frames $start $end
if (-not $sourceValidation.validCapture) { throw 'Original capture must pass before running mutated cases.' }
$originalJson = Get-Content -LiteralPath $sources.json -Raw -Encoding UTF8
$sourceJsonWrite = [IO.File]::GetLastWriteTimeUtc($sources.json)
$sourceCsvWrite = [IO.File]::GetLastWriteTimeUtc($sources.frames)

$null = New-Item -ItemType Directory -Path $output -ErrorAction Stop
$checks = @()
foreach ($case in @('legacy', 'stable-enabled', 'stable-disabled', 'changed-event',
    'changed-end', 'missing-feature', 'string-semantics')) {
    $json = ConvertFrom-Json -InputObject $originalJson
    # Current captures already contain accessibility; legacy must remove it,
    # and each new case must replace it rather than Add-Member failing early.
    $json.environment.PSObject.Properties.Remove('accessibility')
    if ($case -ne 'legacy') {
        $snapshots = [ordered]@{}
        foreach ($name in @('initial', 'measurementStart', 'measurementEnd')) {
            $features = [ordered]@{}
            foreach ($feature in @('accessibleNavigation', 'invertColors', 'disableAnimations',
                'boldText', 'reduceMotion', 'highContrast', 'onOffSwitchLabels', 'supportsAnnounce')) {
                $features[$feature] = $false
            }
            $snapshots[$name] = [ordered]@{ semanticsEnabled = ($case -ne 'stable-disabled'); features = $features }
        }
        $snapshots.changesDuringMeasurement = @()
        switch ($case) {
            'changed-event' {
                $snapshots.changesDuringMeasurement = @(@{ elapsedMs = 12000; source = 'semanticsEnabled'; snapshot = $snapshots.measurementEnd })
            }
            'changed-end' { $snapshots.measurementEnd.features.boldText = $true }
            'missing-feature' { $snapshots.measurementEnd.features.Remove('reduceMotion') }
            'string-semantics' { $snapshots.measurementStart.semanticsEnabled = 'true' }
        }
        $json.environment | Add-Member -NotePropertyName accessibility -NotePropertyValue $snapshots -Force
    }
    $jsonPath = Join-Path $output "$case.json"
    $csvPath = Join-Path $output "$case.frames.csv"
    Write-NewEvidenceText $jsonPath ($json | ConvertTo-Json -Depth 20)
    Assert-NoLinkedAncestors $csvPath
    [IO.File]::Copy($sources.frames, $csvPath, $false)
    # Validation checks the original process interval, not this test's run time.
    [IO.File]::SetLastWriteTimeUtc($jsonPath, $sourceJsonWrite)
    [IO.File]::SetLastWriteTimeUtc($csvPath, $sourceCsvWrite)
    $accepted = $false
    $reason = $null
    try { $accepted = (Test-CaptureEvidence $jsonPath $csvPath $start $end).validCapture }
    catch { $reason = $_.Exception.Message }
    $expected = $case -in @('legacy', 'stable-enabled', 'stable-disabled')
    $checks += [ordered]@{ name = $case; passed = ($accepted -eq $expected); expectedAccepted = $expected; accepted = $accepted; reason = $reason }
}
$hashesAfter = Get-SourceHashes $sources
$unchanged = $true
foreach ($key in $sources.Keys) {
    if ($hashesBefore[$key] -cne $hashesAfter[$key]) { $unchanged = $false }
}
$result = [ordered]@{
    schemaVersion = 1
    passed = $unchanged -and @($checks | Where-Object { -not $_.passed }).Count -eq 0
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    wrapper = $wrapper; wrapperSha256 = $wrapperHash
    evidenceDirectory = $evidence; runName = $RunName; outputDirectory = $output
    sources = $sources; sourceHashesBefore = $hashesBefore; sourceHashesAfter = $hashesAfter
    sourceCaptureValidated = $true; sourceEvidenceUnchanged = $unchanged
    appLaunched = $false
    checks = $checks
}
Write-NewEvidenceText (Join-Path $output 'results.json') ($result | ConvertTo-Json -Depth 10)
$result | ConvertTo-Json -Depth 10
if (-not $result.passed) { exit 1 }
exit 0
