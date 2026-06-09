param(
  [string]$HostOutput = "apps/windows-host/bin/Debug/net8.0-windows10.0.19041.0",
  [string]$OutputDirectory = "artifacts",
  [string]$ArtifactName = "quotio-windows-preview.zip",
  [string]$VerifyDirectory = "artifacts/quotio-windows-preview-verify",
  [string]$CommitSha = ""
)

$ErrorActionPreference = "Stop"

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
}

$hash = Get-FileHash -Path $zipPath -Algorithm SHA256
$shaPath = "$zipPath.sha256"
"$($hash.Hash.ToLowerInvariant())  $ArtifactName" | Set-Content -Path $shaPath -Encoding utf8

$manifestPath = "$zipPath.manifest.json"
$manifest = [ordered]@{
  artifact = $ArtifactName
  sha256 = $hash.Hash.ToLowerInvariant()
  commit = $CommitSha
  hostOutput = $HostOutput
  requiredFiles = $requiredFiles
  installer = $false
  signing = $false
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding utf8

Write-Host "Packaged Windows preview: $zipPath"
Write-Host "SHA256: $($hash.Hash.ToLowerInvariant())"
Write-Host "Manifest: $manifestPath"
