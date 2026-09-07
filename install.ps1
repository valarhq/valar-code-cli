# install.ps1 — installs the valar CLI on Windows (the counterpart of install.sh).
#
#   irm https://raw.githubusercontent.com/valarhq/valar-code-cli/main/install.ps1 | iex
#
# Knobs are env vars (a piped script takes no parameters), mirroring install.sh:
#
#   VALAR_VERSION  release tag to install (default: the latest non-prerelease)
#   VALAR_PREFIX   install directory (default: %USERPROFILE%\.local\bin)
#   VALAR_REPO     GitHub repo to install from (default: valarhq/valar-code-cli)
#   VALAR_NAME     asset + binary base name (default: valar)
#   VALAR_ARCH     amd64 | arm64 (default: the OS architecture)
#   GITHUB_TOKEN   optional; lifts the API rate limit (required if VALAR_REPO is not public).
#
# Every download goes through the GitHub releases API.

$ErrorActionPreference = 'Stop'
# The progress bar makes Invoke-WebRequest an order of magnitude slower on PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'
# Windows PowerShell 5.1 still defaults to TLS 1.0, which GitHub refuses.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo    = if ($env:VALAR_REPO)    { $env:VALAR_REPO }    else { 'valarhq/valar-code-cli' }
$name    = if ($env:VALAR_NAME)    { $env:VALAR_NAME }    else { 'valar' }
$prefix  = if ($env:VALAR_PREFIX)  { $env:VALAR_PREFIX }  else { Join-Path $env:USERPROFILE '.local\bin' }
$arch    = if ($env:VALAR_ARCH)    { $env:VALAR_ARCH }    else {
  switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
    'Arm64'  { 'arm64' }
    'X64'    { 'amd64' }
    default  { throw "install.ps1: unsupported architecture '$_' (set VALAR_ARCH=amd64|arm64)" }
  }
}

$headers = @{ 'User-Agent' = 'valar-install.ps1'; 'Accept' = 'application/vnd.github+json' }
if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }

# ---- resolve the release ----
$api = "https://api.github.com/repos/$repo/releases"
$release = if ($env:VALAR_VERSION) {
  Invoke-RestMethod "$api/tags/$env:VALAR_VERSION" -Headers $headers
} else {
  Invoke-RestMethod "$api/latest" -Headers $headers
}
$version = $release.tag_name
$asset   = "$name-windows-$arch.exe"
Write-Host "==> $name $version for windows/$arch"

$tmp = Join-Path ([IO.Path]::GetTempPath()) "valar-install-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Get-Asset([string]$assetName, [switch]$Optional) {
  $a = $release.assets | Where-Object { $_.name -eq $assetName }
  if (-not $a) {
    if ($Optional) { return $null }
    throw "install.ps1: release $version has no asset '$assetName'"
  }
  # The asset endpoint 302s to a pre-signed storage URL. Validated on PowerShell 5.1:
  # whether or not the client forwards Authorization across that redirect
  # (version-dependent), the download succeeds.
  $h = $headers.Clone(); $h['Accept'] = 'application/octet-stream'
  $out = Join-Path $tmp $assetName
  Invoke-WebRequest $a.url -Headers $h -OutFile $out -UseBasicParsing
  return $out
}

$bin_tmp   = Get-Asset $asset
$checksums = Get-Asset 'checksums.txt'

# ---- verify SHA256 (mandatory, fails closed) ----
# Entries are "<hex>  <name>"; match on the basename so a "dist/"-prefixed line also counts.
$want = $null
foreach ($line in Get-Content $checksums) {
  if ($line -match "^([0-9a-fA-F]{64})\s+\*?(?:.*[\\/])?$([regex]::Escape($asset))$") { $want = $Matches[1].ToLower(); break }
}
if (-not $want) { throw "install.ps1: no checksum entry for $asset in checksums.txt" }
$got = (Get-FileHash $bin_tmp -Algorithm SHA256).Hash.ToLower()
if ($got -ne $want) { throw "install.ps1: SHA256 verification FAILED for $asset (want $want, got $got)" }
Write-Host "    sha256: OK"

# ---- verify cosign signature (optional; the public release signs checksums.txt) ----
$bundle = Get-Asset 'checksums.txt.bundle' -Optional
if ((Get-Command cosign -ErrorAction SilentlyContinue) -and $bundle) {
  $identity = "https://github.com/valarhq/valar-monorepo/.github/workflows/release-valar-code.yml@refs/tags/$version"
  & cosign verify-blob --certificate-identity $identity `
      --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' `
      --bundle $bundle $checksums 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'install.ps1: cosign signature verification FAILED' }
  Write-Host "    cosign: OK (provenance verified)"
} else {
  Write-Host "    cosign: skipped (install cosign to verify provenance; see SECURITY.md)"
}

# ---- install (always overwrites $prefix\$name.exe with the resolved version) ----
New-Item -ItemType Directory -Force $prefix | Out-Null
$bin = Join-Path $prefix "$name.exe"
$old = "$bin.old"
# A running exe can't be overwritten but can be renamed aside — the same dance as
# `valar upgrade`. The .old is swept here if it is free, else by the next install/upgrade.
Remove-Item $old -Force -ErrorAction SilentlyContinue
if (Test-Path $bin) { Move-Item $bin $old -Force }
Move-Item $bin_tmp $bin -Force
Remove-Item $old -Force -ErrorAction SilentlyContinue
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
# Integrity was verified above; drop the mark-of-the-web so the first run isn't blocked.
Unblock-File $bin -ErrorAction SilentlyContinue

# ---- PATH (user scope; no elevation) ----
# A fresh profile has no user-scoped Path at all (null), distinct from the system Path.
$userPath = [string][Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $prefix) {
  [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ";$prefix").TrimStart(';'), 'User')
  Write-Host "    added $prefix to your user PATH (new terminals pick it up)"
}
if (($env:Path -split ';') -notcontains $prefix) { $env:Path += ";$prefix" }

Write-Host "    installed: $bin"
& $bin --version
