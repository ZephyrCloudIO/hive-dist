#Requires -Version 5.1
<#
.SYNOPSIS
  install.ps1 — hive-fleet native-Windows installer.

.DESCRIPTION
  Downloads the fleet-member binaries for windows-x64 from the latest (or a
  pinned) GitHub Release of the distribution repo, verifies the archive's
  SHA-256 against the release's sha256sums.txt manifest, and installs the
  binaries into InstallDir (default %LOCALAPPDATA%\Programs\hive\bin), adding
  that directory to the user Path when it is not already there.

  Trust model: the digest in the release manifest is the ONLY trust anchor —
  there is no code signing. This script refuses to install anything whose
  digest does not match the manifest, and it never executes downloaded bytes
  before that check passes.

.EXAMPLE
  irm https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/install.ps1 | iex

.EXAMPLE
  .\install.ps1 -Version v0.1.3 -InstallDir C:\tools\hive\bin
#>
[CmdletBinding()]
param(
  [string]$TargetRepo = 'ZephyrCloudIO/hive-dist',
  [string]$Version = 'latest',
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\hive\bin')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The fleet-member binaries every release ships. Baked at publish time; the
# rail's dist-scripts template keeps this list in one place.
$Binaries = @('hive-daemon', 'hive-updater', 'hive-iroh-peer', 'hive-iroh-bench', 'model-host')

function Write-Info([string]$Message) {
  Write-Host "install: $Message"
}

function Stop-Install([string]$Message) {
  Write-Host "install: error: $Message" -ForegroundColor Red
  exit 1
}

if ($env:PROCESSOR_ARCHITECTURE -notin @('AMD64')) {
  Stop-Install "unsupported Windows architecture: $env:PROCESSOR_ARCHITECTURE (only windows-x64 is published)"
}
$Platform = 'windows-x64'
Write-Info "platform: $Platform"
Write-Info "target repo: $TargetRepo"

if ($Version -eq 'latest') {
  $releaseApi = "https://api.github.com/repos/$TargetRepo/releases/latest"
  $releaseBase = "https://github.com/$TargetRepo/releases/latest/download"
} else {
  $releaseApi = "https://api.github.com/repos/$TargetRepo/releases/tags/$Version"
  $releaseBase = "https://github.com/$TargetRepo/releases/download/$Version"
}

try {
  $release = Invoke-RestMethod -Uri $releaseApi -Headers @{ 'User-Agent' = 'hive-fleet-install' }
} catch {
  Stop-Install "could not resolve release ($Version) for ${TargetRepo}: $($_.Exception.Message)"
}
$Tag = [string]$release.tag_name
if ([string]::IsNullOrWhiteSpace($Tag)) {
  Stop-Install "empty tag_name in release response for $TargetRepo ($Version)"
}
Write-Info "release: $Tag"

$Archive = "hive-fleet-$Platform.zip"
$workdir = Join-Path ([System.IO.Path]::GetTempPath()) ("hive-fleet-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workdir -Force | Out-Null

try {
  $archivePath = Join-Path $workdir $Archive
  $manifestPath = Join-Path $workdir 'sha256sums.txt'

  Write-Info "downloading $Archive"
  try {
    Invoke-WebRequest -Uri "$releaseBase/$Archive" -OutFile $archivePath -UseBasicParsing
  } catch {
    Stop-Install "download failed: $releaseBase/$Archive — $($_.Exception.Message)"
  }

  Write-Info "downloading sha256sums.txt"
  try {
    Invoke-WebRequest -Uri "$releaseBase/sha256sums.txt" -OutFile $manifestPath -UseBasicParsing
  } catch {
    Stop-Install "download failed: $releaseBase/sha256sums.txt (release $Tag has no manifest?) — $($_.Exception.Message)"
  }

  # --- digest verification (the trust anchor) ---------------------------------
  $expected = $null
  foreach ($line in Get-Content $manifestPath) {
    $parts = $line -split '\s+'
    if ($parts.Count -ge 2 -and $parts[1].TrimStart('*') -eq $Archive) {
      $expected = $parts[0].ToLowerInvariant()
      break
    }
  }
  if ($null -eq $expected) {
    Stop-Install "$Archive not listed in sha256sums.txt for release $Tag"
  }

  $actual = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expected) {
    Write-Host "install: error: DIGEST MISMATCH for $Archive" -ForegroundColor Red
    Write-Host "  expected (manifest): $expected" -ForegroundColor Red
    Write-Host "  actual   (download): $actual" -ForegroundColor Red
    Stop-Install "refusing to install — the download is not what release $Tag published"
  }
  Write-Info "digest verified: $actual"

  # --- unpack -------------------------------------------------------------------
  $unpacked = Join-Path $workdir 'unpacked'
  try {
    Expand-Archive -Path $archivePath -DestinationPath $unpacked -Force
  } catch {
    Stop-Install "failed to unpack ${Archive}: $($_.Exception.Message)"
  }

  # --- install ------------------------------------------------------------------
  if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  }

  foreach ($bin in $Binaries) {
    $src = Join-Path $unpacked "$bin.exe"
    if (-not (Test-Path $src)) {
      Stop-Install "archive $Archive did not contain $bin.exe"
    }
    Copy-Item -Path $src -Destination (Join-Path $InstallDir "$bin.exe") -Force
    Write-Info "installed $(Join-Path $InstallDir "$bin.exe")"
  }

  # --- PATH ---------------------------------------------------------------------
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($null -eq $userPath) { $userPath = '' }
  $pathEntries = $userPath -split ';' | Where-Object { $_ -ne '' }
  if ($pathEntries -notcontains $InstallDir) {
    [Environment]::SetEnvironmentVariable('Path', ($pathEntries + $InstallDir) -join ';', 'User')
    Write-Info "added $InstallDir to the user Path (open a new terminal to pick it up)"
  }

  Write-Info "done. Verify with: irm https://raw.githubusercontent.com/$TargetRepo/main/validate.ps1 | iex"
} finally {
  Remove-Item -Path $workdir -Recurse -Force -ErrorAction SilentlyContinue
}
