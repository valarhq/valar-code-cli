# install.ps1 against a local stand-in for https://app.valarhq.ai/cli/latest (tests/serve.py on
# $Port, fixtures from tests/prepare.sh in $Fix), run the way customers run it (irm | iex) in the
# PowerShell running this script: served from there when it verifies, and the GitHub release on
# every failure. Each case installs into a throwaway folder.
param([string]$Fix, [int]$Port)
$ErrorActionPreference = 'Stop'
$tag = (Get-Content (Join-Path $Fix 'TAG')).Trim()
$url = "http://127.0.0.1:$Port"
$script:fail = $false

# Run-Case <name> <want version> <want source: hosted|github> <env> [<want in output, or !<not in output>>]
function Run-Case([string]$name, [string]$want, [string]$src, [hashtable]$envs, [string]$wantOut = '') {
  $dir = Join-Path ([IO.Path]::GetTempPath()) ("valar-t-" + [guid]::NewGuid().ToString('N'))
  $saved = @{}
  foreach ($k in @('VALAR_DOWNLOAD_URL', 'VALAR_VERSION', 'VALAR_PREFIX', 'VALAR_NO_SETUP', 'STUB_NO_SETUP')) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $null) }
  $env:VALAR_PREFIX = Join-Path $dir 'bin'
  foreach ($k in $envs.Keys) { [Environment]::SetEnvironmentVariable($k, $envs[$k]) }
  $out = ''
  try {
    $out = (& { Invoke-RestMethod "$url/install.ps1" | Invoke-Expression } *>&1 | Out-String)
  } catch {
    $out += "THREW: $($_.Exception.Message)"
  }
  $got = ''
  $exe = Join-Path $env:VALAR_PREFIX 'valar.exe'
  if (Test-Path $exe) { $got = ((& $exe --version 2>$null) -join '').Trim().Split(' ')[-1] }
  $ok = ($got -eq $want)
  if ($src -eq 'hosted' -and $out -match '\(from GitHub\)') { $ok = $false }
  if ($src -eq 'github' -and $out -notmatch '\(from GitHub\)') { $ok = $false }
  if ($wantOut.StartsWith('!')) {
    if ($out.Contains($wantOut.Substring(1))) { $ok = $false }
  } elseif ($wantOut -and -not $out.Contains($wantOut)) { $ok = $false }
  if ($ok) { Write-Host "ok    $name ($got from $src)" } else { Write-Host "FAIL  ${name}: got '$got', want '$want' from $src, '$wantOut' in output`n$out"; $script:fail = $true }
  foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
Run-Case 'latest from the hosted copy'          $tag hosted @{ VALAR_DOWNLOAD_URL = "$url/good/latest" }
Run-Case 'pinned to the latest: hosted copy'    $tag hosted @{ VALAR_DOWNLOAD_URL = "$url/good/latest"; VALAR_VERSION = $tag }
Run-Case 'a binary that does not verify: GitHub' $tag github @{ VALAR_DOWNLOAD_URL = "$url/bad/latest" }
Run-Case 'a missing binary: GitHub'             $tag github @{ VALAR_DOWNLOAD_URL = "$url/nobin/latest" }
Run-Case 'host unreachable: GitHub'             $tag github @{ VALAR_DOWNLOAD_URL = 'http://127.0.0.1:1/latest' }
Run-Case 'VALAR_DOWNLOAD_URL=github'            $tag github @{ VALAR_DOWNLOAD_URL = 'github' }
$older = (gh release list --repo valarhq/valar-code-cli --limit 2 --json tagName --jq '.[1].tagName')
Run-Case 'pinned to an older release: GitHub'   $older github @{ VALAR_DOWNLOAD_URL = "$url/good/latest"; VALAR_VERSION = $older }

# The hand-over to `valar setup`, against the stub. CI runs PowerShell without a console, so these
# are the cases that install only.
$stub = 'valar-cli-v0.0.0-stub'
Run-Case 'no console: installs only'                  $stub hosted @{ VALAR_DOWNLOAD_URL = "$url/stub/latest" } 'next: valar setup'
Run-Case 'VALAR_NO_SETUP=1: installs only'            $stub hosted @{ VALAR_DOWNLOAD_URL = "$url/stub/latest"; VALAR_NO_SETUP = '1' } 'next: valar setup'
Run-Case 'a release without setup: as before'         $stub hosted @{ VALAR_DOWNLOAD_URL = "$url/stub/latest"; STUB_NO_SETUP = '1' } '!next:'
if ($script:fail) { exit 1 }
