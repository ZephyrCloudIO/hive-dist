#Requires -Version 5.1
<#
.SYNOPSIS
  validate.ps1 — prove an installed hive-fleet copy is exactly what the
  release published (native Windows).

.DESCRIPTION
  For every fleet-member binary in InstallDir:
    1. re-compute its SHA-256 and compare it against the digest of the same
       binary taken from a freshly downloaded, manifest-verified copy of the
       release archive (the manifest pins the ARCHIVE's digest; per-binary
       reference bytes come only from an archive that passed that check),
    2. run '<binary> --version' and require exit code 0.

  Any mismatch or any failing binary prints a loud diagnosis; the script
  exits 1 if any check failed, 0 only when every binary verifies and runs.

.EXAMPLE
  irm https://raw.githubusercontent.com/ZephyrCloudIO/hive-dist/main/validate.ps1 | iex

.EXAMPLE
  .\validate.ps1 -Version v0.1.3 -InstallDir C:\tools\hive\bin
#>
[CmdletBinding()]
param(
  [string]$TargetRepo = 'ZephyrCloudIO/hive-dist',
  [string]$Version = 'latest',
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\hive\bin')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Binaries = @('hive-daemon', 'hive-updater', 'hive-iroh-peer', 'hive-iroh-bench', 'model-host')

$script:Failures = 0

function Write-Ok([string]$Message) {
  Write-Host "validate: OK: $Message"
}

function Write-Fail([string]$Message) {
  Write-Host "validate: FAIL: $Message" -ForegroundColor Red
  $script:Failures += 1
}

function Stop-Validate([string]$Message) {
  Write-Host "validate: error: $Message" -ForegroundColor Red
  exit 1
}

if ($env:PROCESSOR_ARCHITECTURE -notin @('AMD64')) {
  Stop-Validate "unsupported Windows architecture: $env:PROCESSOR_ARCHITECTURE (only windows-x64 is published)"
}
$Platform = 'windows-x64'
Write-Host "validate: platform: $Platform"
Write-Host "validate: install dir: $InstallDir"
Write-Host "validate: target repo: $TargetRepo"

if ($Version -eq 'latest') {
  $releaseApi = "https://api.github.com/repos/$TargetRepo/releases/latest"
  $releaseBase = "https://github.com/$TargetRepo/releases/latest/download"
} else {
  $releaseApi = "https://api.github.com/repos/$TargetRepo/releases/tags/$Version"
  $releaseBase = "https://github.com/$TargetRepo/releases/download/$Version"
}

try {
  $release = Invoke-RestMethod -Uri $releaseApi -Headers @{ 'User-Agent' = 'hive-fleet-validate' }
} catch {
  Stop-Validate "could not resolve release ($Version) for ${TargetRepo}: $($_.Exception.Message)"
}
$Tag = [string]$release.tag_name
if ([string]::IsNullOrWhiteSpace($Tag)) {
  Stop-Validate "empty tag_name in release response for $TargetRepo ($Version)"
}
Write-Host "validate: release: $Tag"

$Archive = "hive-fleet-$Platform.zip"
$workdir = Join-Path ([System.IO.Path]::GetTempPath()) ("hive-fleet-validate-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workdir -Force | Out-Null

try {
  $archivePath = Join-Path $workdir $Archive
  $manifestPath = Join-Path $workdir 'sha256sums.txt'

  try {
    Invoke-WebRequest -Uri "$releaseBase/$Archive" -OutFile $archivePath -UseBasicParsing
    Invoke-WebRequest -Uri "$releaseBase/sha256sums.txt" -OutFile $manifestPath -UseBasicParsing
  } catch {
    Stop-Validate "download failed from $releaseBase — $($_.Exception.Message)"
  }

  # Verify the ARCHIVE against the manifest first — everything below trusts
  # only bytes that passed this check.
  $expectedArchive = $null
  foreach ($line in Get-Content $manifestPath) {
    $parts = $line -split '\s+'
    if ($parts.Count -ge 2 -and $parts[1].TrimStart('*') -eq $Archive) {
      $expectedArchive = $parts[0].ToLowerInvariant()
      break
    }
  }
  if ($null -eq $expectedArchive) {
    Stop-Validate "$Archive not listed in sha256sums.txt for release $Tag"
  }
  $actualArchive = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualArchive -ne $expectedArchive) {
    Write-Host "validate: error: DIGEST MISMATCH for reference archive $Archive" -ForegroundColor Red
    Write-Host "  expected (manifest): $expectedArchive" -ForegroundColor Red
    Write-Host "  actual   (download): $actualArchive" -ForegroundColor Red
    Stop-Validate "cannot validate — the published reference bytes do not match the manifest"
  }
  Write-Host "validate: reference archive digest verified: $actualArchive"

  $ref = Join-Path $workdir 'ref'
  try {
    Expand-Archive -Path $archivePath -DestinationPath $ref -Force
  } catch {
    Stop-Validate "failed to unpack ${Archive}: $($_.Exception.Message)"
  }

  foreach ($bin in $Binaries) {
    $installed = Join-Path $InstallDir "$bin.exe"
    $reference = Join-Path $ref "$bin.exe"

    if (-not (Test-Path $installed)) {
      Write-Fail "$bin.exe is not installed at $installed"
      continue
    }
    if (-not (Test-Path $reference)) {
      Write-Fail "reference archive $Archive did not contain $bin.exe"
      continue
    }

    $installedDigest = (Get-FileHash -Path $installed -Algorithm SHA256).Hash.ToLowerInvariant()
    $refDigest = (Get-FileHash -Path $reference -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($installedDigest -ne $refDigest) {
      Write-Fail "$bin.exe digest mismatch: on-disk $installedDigest != published $refDigest"
    } else {
      Write-Ok "$bin.exe digest matches release $Tag ($installedDigest)"
    }

    $versionOk = $false
    try {
      $null = & $installed --version 2>&1
      $versionOk = ($LASTEXITCODE -eq 0)
    } catch {
      $versionOk = $false
    }
    if ($versionOk) {
      Write-Ok "$bin.exe --version exits 0"
    } else {
      Write-Fail "$bin.exe --version did not exit 0"
    }
  }

  if ($script:Failures -gt 0) {
    Write-Host "validate: $script:Failures check(s) FAILED — the install is NOT what release $Tag published" -ForegroundColor Red
    exit 1
  }

  Write-Host "validate: all $($Binaries.Count) binaries verified against release $Tag"
} finally {
  Remove-Item -Path $workdir -Recurse -Force -ErrorAction SilentlyContinue
}
