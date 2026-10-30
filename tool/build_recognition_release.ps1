[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RecognitionUrl,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\build\recognition-delivery')
)

$ErrorActionPreference = 'Stop'
$gatewayUri = $null
if (-not [Uri]::TryCreate($RecognitionUrl, [UriKind]::Absolute, [ref]$gatewayUri) -or
    $gatewayUri.Scheme -ne 'https' -or $gatewayUri.Host.Length -eq 0 -or
    $gatewayUri.IsLoopback -or $gatewayUri.UserInfo.Length -ne 0 -or
    $gatewayUri.Query.Length -ne 0 -or $gatewayUri.Fragment.Length -ne 0 -or
    $gatewayUri.AbsolutePath -ne '/v1/recognize') {
    throw 'RecognitionUrl must be the deployed HTTPS /v1/recognize endpoint, without credentials, query or fragment.'
}
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$deliveryRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $deliveryRoot -Force | Out-Null
Push-Location $repositoryRoot
try {
    & dart "-DHANMUSIC_RECOGNITION_URL=$($gatewayUri.AbsoluteUri)" tool/validate_recognition_endpoint.dart
    if ($LASTEXITCODE -ne 0) { throw 'Recognition endpoint was rejected by the client configuration validator.' }
    # The server URL is public configuration. A vendor API token is never passed
    # to Flutter, dart-define, this script or the generated client archive.
    & flutter --no-version-check build windows --release --no-pub "--dart-define=HANMUSIC_RECOGNITION_URL=$($gatewayUri.AbsoluteUri)"
    if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed.' }
    $releaseRoot = Join-Path $repositoryRoot 'build\windows\x64\runner\Release'
    foreach ($required in @('han_music.exe', 'flutter_windows.dll', 'data\app.so')) {
        if (-not (Test-Path -LiteralPath (Join-Path $releaseRoot $required) -PathType Leaf)) {
            throw "Release file is missing: $required"
        }
    }
    $clientZip = Join-Path $deliveryRoot 'hanmusic-windows-recognition.zip'
    Compress-Archive -LiteralPath $releaseRoot -DestinationPath $clientZip -Force
    [ordered]@{
        recognitionUrl = $gatewayUri.AbsoluteUri
        vendorCredentialsIncluded = $false
        sha256 = (Get-FileHash -LiteralPath $clientZip -Algorithm SHA256).Hash
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $deliveryRoot 'client-release.json') -Encoding utf8
    [pscustomobject]@{ Package=$clientZip; RecognitionUrl=$gatewayUri.AbsoluteUri }
} finally { Pop-Location }
