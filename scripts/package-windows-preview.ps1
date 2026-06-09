param(
  [string]$HostOutput = "apps/windows-host/bin/Release/net8.0-windows10.0.19041.0",
  [string]$Configuration = "Release",
  [string]$OutputDirectory = "artifacts",
  [string]$ArtifactName = "quotio-windows-preview.zip",
  [string]$VerifyDirectory = "artifacts/quotio-windows-preview-verify",
  [string]$CommitSha = ""
)

$ErrorActionPreference = "Stop"

function Write-Utf8LfFile {
  param(
    [string]$Path,
    [string]$Content
  )

  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

if (!(Test-Path $HostOutput)) {
  throw "Windows host output not found: $HostOutput"
}

$requiredFiles = @(
  "desktop-ui/index.html",
  "Quotio.Windows.exe"
)

foreach ($requiredFile in $requiredFiles) {
  $path = Join-Path $HostOutput $requiredFile
  if (!(Test-Path $path)) {
    throw "Windows host output is missing required file: $path"
  }
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$zipPath = Join-Path $OutputDirectory $ArtifactName
Compress-Archive -Path (Join-Path $HostOutput "*") -DestinationPath $zipPath -Force

Remove-Item -Recurse -Force $VerifyDirectory -ErrorAction SilentlyContinue
Expand-Archive -Path $zipPath -DestinationPath $VerifyDirectory -Force

foreach ($requiredFile in $requiredFiles) {
  $path = Join-Path $VerifyDirectory $requiredFile
  if (!(Test-Path $path)) {
    throw "Windows preview zip is missing required file: $requiredFile"
  }
  if ((Get-Item $path).Length -le 0) {
    throw "Windows preview zip contains an empty required file: $requiredFile"
  }
}

$requiredFileDetails = foreach ($requiredFile in $requiredFiles) {
  $path = Join-Path $VerifyDirectory $requiredFile
  $file = Get-Item $path
  $fileHash = Get-FileHash -Path $path -Algorithm SHA256
  [ordered]@{
    path = $requiredFile
    bytes = $file.Length
    sha256 = $fileHash.Hash.ToLowerInvariant()
  }
}

$hash = Get-FileHash -Path $zipPath -Algorithm SHA256
$shaPath = "$zipPath.sha256"
Write-Utf8LfFile -Path $shaPath -Content "$($hash.Hash.ToLowerInvariant())  $ArtifactName`n"

$manifestPath = "$zipPath.manifest.json"
$manifest = [ordered]@{
  artifact = $ArtifactName
  sha256 = $hash.Hash.ToLowerInvariant()
  commit = $CommitSha
  hostOutput = $HostOutput
  configuration = $Configuration
  requiredFiles = $requiredFiles
  requiredFileDetails = $requiredFileDetails
  installer = $false
  signing = $false
}

Write-Utf8LfFile -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 4) + "`n")

Write-Host "Packaged Windows preview: $zipPath"
Write-Host "SHA256: $($hash.Hash.ToLowerInvariant())"
Write-Host "Manifest: $manifestPath"
