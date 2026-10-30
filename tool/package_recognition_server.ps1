[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\build\recognition-delivery')
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$serverRoot = (Resolve-Path -LiteralPath (Join-Path $repositoryRoot 'server\recognition')).Path
$deliveryRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $deliveryRoot -Force | Out-Null
$zipPath = Join-Path $deliveryRoot 'hanmusic-recognition-server.zip'
$requiredFiles = @('package.json', 'Dockerfile', '.dockerignore', '.gitignore', '.env.example', 'Caddyfile.example', 'README.md')
$files = @($requiredFiles | ForEach-Object { Get-Item -LiteralPath (Join-Path $serverRoot $_) })
foreach ($sourceDirectory in @('src', 'test')) {
    $files += @(Get-ChildItem -LiteralPath (Join-Path $serverRoot $sourceDirectory) -File -Filter '*.js' -Recurse)
}
if ($files.Count -lt 8) { throw 'The recognition server sources are incomplete.' }

# An allowlist keeps real .env files, quotas, logs and credentials out of delivery.
Add-Type -AssemblyName System.IO.Compression
$stream = [IO.File]::Open($zipPath, [IO.FileMode]::Create)
try {
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($serverRoot, $file.FullName).Replace('\', '/')
            if ($relative.StartsWith('../') -or $relative -eq '.env' -or $relative.StartsWith('data/')) {
                throw 'A file outside the deployment allowlist was encountered.'
            }
            $entry = $archive.CreateEntry("hanmusic-recognition-server/$relative", [IO.Compression.CompressionLevel]::Optimal)
            $destination = $entry.Open()
            $source = [IO.File]::OpenRead($file.FullName)
            try { $source.CopyTo($destination) } finally { $source.Dispose(); $destination.Dispose() }
        }
    } finally { $archive.Dispose() }
} finally { $stream.Dispose() }
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
"$hash  hanmusic-recognition-server.zip" | Set-Content -LiteralPath (Join-Path $deliveryRoot 'SHA256SUMS.txt') -Encoding ascii
[pscustomobject]@{ Package=$zipPath; Files=$files.Count; SHA256=$hash }
