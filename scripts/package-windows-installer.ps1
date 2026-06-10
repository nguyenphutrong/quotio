param(
  [string]$Project = "apps/windows-host/Quotio.Windows.csproj",
  [string]$Configuration = "Release",
  [string]$Runtime = "win-x64",
  [string]$Version = "0.1.0",
  [string]$Channel = "stable",
  [string]$PublishDirectory = "artifacts/windows-publish/win-x64",
  [string]$OutputDirectory = "artifacts/windows-installer",
  [string]$ToolPath = "artifacts/.tools",
  [string]$CommitSha = "",
  [string]$SignTemplate = ""
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

function Resolve-VpkPath {
  param([string]$ToolPath)

  $extension = if ($IsWindows) { ".exe" } else { "" }
  $vpkPath = Join-Path $ToolPath "vpk$extension"
  if (!(Test-Path $vpkPath)) {
    New-Item -ItemType Directory -Force -Path $ToolPath | Out-Null
    dotnet tool update vpk --tool-path $ToolPath --version 1.2.0
  }

  if (!(Test-Path $vpkPath)) {
    throw "Velopack CLI was not installed at $vpkPath"
  }

  return $vpkPath
}

if ($Channel -ne "stable" -and $Channel -ne "beta") {
  throw "Channel must be stable or beta."
}

if (!(Test-Path "apps/desktop-ui/dist/index.html")) {
  throw "Desktop UI build output is missing. Run bun run build before packaging."
}

Remove-Item -Recurse -Force $PublishDirectory -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $OutputDirectory -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $PublishDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

dotnet publish $Project `
  --configuration $Configuration `
  --runtime $Runtime `
  --self-contained true `
  -p:WindowsPackageType=None `
  -p:WindowsAppSDKSelfContained=true `
  -p:Version=$Version `
  -o $PublishDirectory

if (!(Test-Path (Join-Path $PublishDirectory "desktop-ui/index.html"))) {
  Copy-Item -Recurse -Force "apps/desktop-ui/dist" (Join-Path $PublishDirectory "desktop-ui")
}

if (!(Test-Path (Join-Path $PublishDirectory "Quotio.Windows.exe"))) {
  throw "Published Windows host is missing Quotio.Windows.exe"
}

if (!(Test-Path (Join-Path $PublishDirectory "desktop-ui/index.html"))) {
  throw "Published Windows host is missing bundled desktop-ui/index.html"
}

$vpk = Resolve-VpkPath -ToolPath $ToolPath
$packArgs = @(
  "pack",
  "--packId", "dev.quotio.Quotio",
  "--packTitle", "Quotio",
  "--packVersion", $Version,
  "--packDir", $PublishDirectory,
  "--mainExe", "Quotio.Windows.exe",
  "--channel", $Channel,
  "--outputDir", $OutputDirectory
)

if (![string]::IsNullOrWhiteSpace($SignTemplate)) {
  $packArgs += @("--signTemplate", $SignTemplate)
}

& $vpk @packArgs

$releaseIndex = Join-Path $OutputDirectory "releases.$Channel.json"
if (!(Test-Path $releaseIndex)) {
  throw "Velopack package is missing releases.$Channel.json"
}

$setup = Get-ChildItem -Path $OutputDirectory -Filter "*.exe" | Select-Object -First 1
if ($null -eq $setup) {
  throw "Velopack package did not produce a setup executable."
}

$setupHash = Get-FileHash -Path $setup.FullName -Algorithm SHA256
Write-Utf8LfFile -Path "$($setup.FullName).sha256" -Content "$($setupHash.Hash.ToLowerInvariant())  $($setup.Name)`n"

$manifestPath = Join-Path $OutputDirectory "quotio-windows-installer.manifest.json"
$manifest = [ordered]@{
  package = "dev.quotio.Quotio"
  version = $Version
  channel = $Channel
  runtime = $Runtime
  commit = $CommitSha
  installer = $true
  signing = ![string]::IsNullOrWhiteSpace($SignTemplate)
  updater = $true
  releaseIndex = "releases.$Channel.json"
  setup = $setup.Name
  setupSha256 = $setupHash.Hash.ToLowerInvariant()
}

Write-Utf8LfFile -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 4) + "`n")

Write-Host "Packaged Windows installer: $($setup.FullName)"
Write-Host "SHA256: $($setupHash.Hash.ToLowerInvariant())"
Write-Host "Manifest: $manifestPath"
