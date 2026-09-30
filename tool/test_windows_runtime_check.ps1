param([string]$ScratchRoot = 'D:\dev\tmp')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$checker = Join-Path $PSScriptRoot 'windows_runtime_check.ps1'
$dotSourceOutput = @(. $checker)
if ($dotSourceOutput.Count -ne 0) { throw 'Dot-sourcing must not run the CLI.' }
$scratchBase = [IO.Path]::GetFullPath($ScratchRoot)
if ($scratchBase -notmatch '^[dD]:[\\/]') { throw 'Tests require an absolute D-drive scratch root.' }
$scratch = Join-Path $scratchBase ('hanmusic-runtime-tests-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $scratch) { throw 'Refusing to overwrite test evidence.' }
[void][IO.Directory]::CreateDirectory($scratch)
$results = New-Object 'System.Collections.Generic.List[object]'

function Assert-RuntimeTest { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Invoke-RuntimeTest {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $results.Add([pscustomobject]@{ name = $Name; passed = $true }) }
    catch { $results.Add([pscustomobject]@{ name = $Name; passed = $false; error = $_.Exception.Message }) }
}
function New-RuntimeFixture {
    param([string]$Name, [bool]$Is64BitProcess = $true)
    $root = Join-Path $scratch $Name
    $package = Join-Path $root 'package'
    $windows = Join-Path $root 'Windows'
    $system = Join-Path $windows $(if ($Is64BitProcess) { 'System32' } else { 'Sysnative' })
    [void][IO.Directory]::CreateDirectory($package)
    [void][IO.Directory]::CreateDirectory($system)
    $requirements = [ordered]@{
        schemaVersion = 1; target = 'windows-x64'; minimumVCRuntimeVersion = '14.37.32822.0'
        requiredVCRuntimeDlls = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
        deployment = 'central'; downloadUrl = 'https://aka.ms/vc14/vc_redist.x64.exe'
        guidanceUrl = 'https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist'
    }
    $fixture = [pscustomobject]@{
        package = $package; system = $system; requirements = $requirements
        versions = @{}; reads = (New-Object 'System.Collections.Generic.List[string]')
        platform = [pscustomobject]@{ operatingSystem = 'Win32NT'; architecture = 'x64'; is64BitProcess = $Is64BitProcess; windowsDirectory = $windows }
    }
    Write-RuntimeRequirements $fixture
    foreach ($name in $requirements.requiredVCRuntimeDlls) { Write-RuntimeFixtureDll $fixture (Join-Path $system $name) }
    return $fixture
}
function Write-RuntimeRequirements {
    param($Fixture)
    [IO.File]::WriteAllText((Join-Path $Fixture.package 'RUNTIME-REQUIREMENTS.json'), ($Fixture.requirements | ConvertTo-Json -Depth 4))
}
function Write-RuntimeFixtureDll {
    param($Fixture, [string]$Path, [int]$Machine = 0x8664, [string]$Version = '14.40.33810.0')
    # A non-executable header fixture. Numeric version facts are injected below;
    # PE parsing and actual candidate-path selection still read real test files.
    $bytes = New-Object byte[] 512
    $bytes[0] = 0x4D; $bytes[1] = 0x5A
    [BitConverter]::GetBytes([int]128).CopyTo($bytes, 0x3C)
    [BitConverter]::GetBytes([int]0x4550).CopyTo($bytes, 128)
    [BitConverter]::GetBytes([uint16]$Machine).CopyTo($bytes, 132)
    [BitConverter]::GetBytes([uint16]240).CopyTo($bytes, 148)
    [BitConverter]::GetBytes([uint16]$(if ($Machine -eq 0x014C) { 0x010B } else { 0x020B })).CopyTo($bytes, 152)
    [IO.File]::WriteAllBytes($Path, $bytes)
    $v = [version]$Version
    $Fixture.versions[[IO.Path]::GetFullPath($Path)] = [pscustomobject]@{
        FileVersion = ($Version + ' (numeric fixture)'); FileMajorPart = $v.Major
        FileMinorPart = $v.Minor; FileBuildPart = $v.Build; FilePrivatePart = $v.Revision
    }
}
function Get-FixtureRuntimeStatus {
    param($Fixture)
    $platformReader = { $Fixture.platform }.GetNewClosure()
    $readFacts = ${function:Get-HanMusicRuntimeDllFacts}
    $dllReader = {
        param($path)
        $Fixture.reads.Add($path)
        $versions = $Fixture.versions
        $versionReader = { param($file) $versions[[IO.Path]::GetFullPath($file)] }.GetNewClosure()
        & $readFacts -LiteralPath $path -VersionReader $versionReader
    }.GetNewClosure()
    Get-HanMusicRuntimeStatus -PackageDirectory $Fixture.package -PlatformReader $platformReader -DllReader $dllReader
}

Invoke-RuntimeTest 'three valid x64 DLLs pass; unrelated JNI is ignored' {
    $f = New-RuntimeFixture 'valid'
    [IO.File]::WriteAllText((Join-Path $f.package 'jni.dll'), 'not a runtime requirement')
    $before = @(Get-ChildItem -LiteralPath (Split-Path $f.package) -File -Recurse | Get-FileHash | ForEach-Object { $_.Hash }) -join ','
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest ($s.passed -and $s.exitCode -eq 0 -and $s.checks.Count -eq 3) 'Valid numeric version/PE fixtures failed.'
    Assert-RuntimeTest (@($s.checks | Where-Object { $_.resolution -ne 'system' }).Count -eq 0) 'Unexpected DLL location.'
    $after = @(Get-ChildItem -LiteralPath (Split-Path $f.package) -File -Recurse | Get-FileHash | ForEach-Object { $_.Hash }) -join ','
    Assert-RuntimeTest ($before -eq $after) 'Preflight changed fixture contents.'
}
Invoke-RuntimeTest 'missing DLL fails' {
    $f = New-RuntimeFixture 'missing'
    $f.platform.windowsDirectory = Join-Path $scratch 'absent-system-directory'
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest (-not $s.passed -and $s.exitCode -eq 2 -and $s.issues[0].code -eq 'missing-dll') 'Missing DLL accepted.'
}
Invoke-RuntimeTest 'old numeric version fails' {
    $f = New-RuntimeFixture 'old'
    Write-RuntimeFixtureDll $f (Join-Path $f.system 'msvcp140.dll') -Version '14.36.9999.0'
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest (-not $s.passed -and $s.issues[0].code -eq 'runtime-too-old') 'Old DLL accepted.'
}
Invoke-RuntimeTest 'exact minimum numeric version passes despite display suffix' {
    $f = New-RuntimeFixture 'exact-minimum'
    foreach ($name in $f.requirements.requiredVCRuntimeDlls) {
        Write-RuntimeFixtureDll $f (Join-Path $f.system $name) -Version '14.37.32822.0'
    }
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest ($s.passed -and $s.checks[0].fileVersion -eq '14.37.32822.0') 'Equal numeric minimum was rejected or display suffix was parsed as the version.'
}
Invoke-RuntimeTest 'x86 PE fails even with a high version' {
    $f = New-RuntimeFixture 'x86'
    Write-RuntimeFixtureDll $f (Join-Path $f.system 'msvcp140.dll') -Machine 0x014C
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest (-not $s.passed -and $s.issues[0].code -eq 'wrong-dll-architecture') 'x86 DLL accepted.'
}
Invoke-RuntimeTest 'corrupt app-local DLL shadows a valid system DLL' {
    $f = New-RuntimeFixture 'shadow'
    [IO.File]::WriteAllText((Join-Path $f.package 'msvcp140.dll'), 'broken PE')
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest (-not $s.passed -and $s.checks[0].resolution -eq 'app-local' -and $s.issues[0].code -eq 'invalid-pe') 'Corrupt app-local DLL accepted.'
    Assert-RuntimeTest (-not $f.reads.Contains((Join-Path $f.system 'msvcp140.dll'))) 'Invalid app-local DLL incorrectly fell back to System32.'
}
Invoke-RuntimeTest 'old app-local DLL also prevents fallback' {
    $f = New-RuntimeFixture 'old-local'
    Write-RuntimeFixtureDll $f (Join-Path $f.package 'msvcp140.dll') -Version '14.0.0.0'
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest (-not $s.passed -and $s.checks[0].resolution -eq 'app-local') 'Old app-local DLL accepted.'
    Assert-RuntimeTest (-not $f.reads.Contains((Join-Path $f.system 'msvcp140.dll'))) 'Old app-local DLL incorrectly fell back.'
}
Invoke-RuntimeTest 'missing FileVersion resource fails closed' {
    $f = New-RuntimeFixture 'unversioned'
    $f.versions[(Join-Path $f.system 'msvcp140.dll')].FileVersion = $null
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest (-not $s.passed -and $s.issues[0].code -eq 'missing-version') 'Unversioned DLL accepted.'
}
Invoke-RuntimeTest 'ARM64 OS is rejected before DLL reads' {
    $f = New-RuntimeFixture 'arm64'
    $f.platform.architecture = 'arm64'
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest (-not $s.passed -and $s.exitCode -eq 2 -and $f.reads.Count -eq 0) 'ARM64 was accepted or probed as x64.'
}
Invoke-RuntimeTest '32-bit PowerShell uses Sysnative on x64 Windows' {
    $f = New-RuntimeFixture 'sysnative' -Is64BitProcess $false
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest ($s.passed -and $s.systemRuntimeDirectory -eq $f.system -and $s.processArchitecture -eq 'x86') '32-bit process did not choose Sysnative.'
}
foreach ($field in @('schemaVersion', 'minimumVCRuntimeVersion', 'requiredVCRuntimeDlls', 'downloadUrl', 'unknownField')) {
    Invoke-RuntimeTest "invalid requirements field: $field" {
        $f = New-RuntimeFixture ('invalid-' + $field)
        switch ($field) {
            'schemaVersion' { $f.requirements[$field] = 2 }
            'minimumVCRuntimeVersion' { $f.requirements[$field] = '14.37' }
            'requiredVCRuntimeDlls' { $f.requirements[$field] = @('../msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') }
            'downloadUrl' { $f.requirements[$field] = 'https://example.invalid/untrusted.exe' }
            'unknownField' { $f.requirements[$field] = 'unexpected' }
        }
        Write-RuntimeRequirements $f
        $s = Get-FixtureRuntimeStatus $f
        Assert-RuntimeTest (-not $s.passed -and $s.exitCode -eq 3 -and $f.reads.Count -eq 0) 'Invalid configuration did not fail before probing.'
    }
}
Invoke-RuntimeTest 'duplicate requirements field fails closed' {
    $f = New-RuntimeFixture 'duplicate-json'
    $path = Join-Path $f.package 'RUNTIME-REQUIREMENTS.json'
    # Use a formatting-independent insertion at the outer object boundary.
    $raw = '{"schemaVersion":1,' + [IO.File]::ReadAllText($path).Trim().Substring(1)
    [IO.File]::WriteAllText($path, $raw)
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest (-not $s.passed -and $s.exitCode -eq 3) 'Duplicate JSON field accepted.'
}
Invoke-RuntimeTest 'malformed requirements JSON fails before probing' {
    $f = New-RuntimeFixture 'malformed-json'
    [IO.File]::WriteAllText((Join-Path $f.package 'RUNTIME-REQUIREMENTS.json'), '{"schemaVersion":')
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest (-not $s.passed -and $s.exitCode -eq 3 -and $f.reads.Count -eq 0) 'Malformed JSON was accepted or triggered DLL reads.'
}
Invoke-RuntimeTest 'out-of-range version part fails before probing' {
    $f = New-RuntimeFixture 'version-part-overflow'
    $f.requirements.minimumVCRuntimeVersion = '14.37.99999.0'
    Write-RuntimeRequirements $f
    $s = Get-FixtureRuntimeStatus $f
    Assert-RuntimeTest (-not $s.passed -and $s.exitCode -eq 3 -and $f.reads.Count -eq 0) 'Invalid numeric version part was accepted.'
}
Invoke-RuntimeTest 'probe exception is not a passing or missing-file result' {
    $f = New-RuntimeFixture 'probe-error'
    $platformReader = { $f.platform }.GetNewClosure()
    $s = Get-HanMusicRuntimeStatus -PackageDirectory $f.package -PlatformReader $platformReader -DllReader { param($path) throw 'Synthetic access denial' }
    Assert-RuntimeTest (-not $s.passed -and $s.exitCode -eq 3 -and $s.status -eq 'probe-error') 'Probe exception was hidden.'
}
Invoke-RuntimeTest 'CLI JSON and exit codes work in Windows PowerShell 5.1' {
    $stock = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $empty = Join-Path $scratch 'cli-empty'
    [void][IO.Directory]::CreateDirectory($empty)
    $raw = & $stock -NoProfile -NonInteractive -File $checker -PackageDirectory $empty -AsJson
    $code = $LASTEXITCODE
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-RuntimeTest ($code -eq 3 -and -not $json.passed -and $json.status -eq 'configuration-error') 'Missing requirements CLI result was invalid.'
    $f = New-RuntimeFixture 'cli-broken-local'
    foreach ($name in $f.requirements.requiredVCRuntimeDlls) { [IO.File]::WriteAllText((Join-Path $f.package $name), 'broken PE') }
    $raw = & $stock -NoProfile -NonInteractive -File $checker -PackageDirectory $f.package -AsJson
    $code = $LASTEXITCODE
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-RuntimeTest ($code -eq 2 -and -not $json.passed -and $json.checks.Count -eq 3) 'Unmet-runtime CLI result was invalid.'
}

$failures = @($results | Where-Object { -not $_.passed })
$report = [pscustomobject]@{ passed = $failures.Count -eq 0; powershell = $PSVersionTable.PSVersion.ToString(); scratchDirectory = $scratch; tests = $results.ToArray() }
[IO.File]::WriteAllText((Join-Path $scratch 'results.json'), ($report | ConvertTo-Json -Depth 6))
foreach ($failure in $failures) { Write-Output ('FAIL {0}: {1}' -f $failure.name, $failure.error) }
Write-Output ('{0}/{1} runtime checks passed; isolated evidence: {2}' -f ($results.Count - $failures.Count), $results.Count, $scratch)
if ($failures.Count -ne 0) { exit 1 }
exit 0
