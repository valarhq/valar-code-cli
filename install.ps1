# install.ps1 - installs the valar CLI on Windows (the counterpart of install.sh).
#
#   irm https://raw.githubusercontent.com/valarhq/valar-code-cli/main/install.ps1 | iex
#
# Knobs are env vars (a piped script takes no parameters), the same three as install.sh:
#
#   VALAR_VERSION  release tag to install (default: the latest release)
#   VALAR_PREFIX   install directory (default: %USERPROFILE%\.local\bin)
#   GITHUB_TOKEN   optional; lifts the GitHub API rate limit
#
# Setup: in a console, the installer then runs `valar login`, reads the organization's
# installation defaults with `valar org-policy`, runs `valar proxy enable` and
# `valar configure --quota-first` when those defaults say so, and ends with `valar on`, where
# you pick your tools. It stops at the first step that fails and prints the steps left. With
# redirected input (a scripted run) it only installs, and prints the commands that finish it. A
# release without the guided setup installs exactly as before it.

# The whole body runs in its own scope: `irm | iex` evaluates in the CALLER's session, and the
# preference variables, the helper function and the token-bearing headers must not outlive
# the install there.
& {
  $ErrorActionPreference = 'Stop'
  # The progress bar makes Invoke-WebRequest an order of magnitude slower on PowerShell 5.1.
  $ProgressPreference = 'SilentlyContinue'
  # Windows PowerShell 5.1 still defaults to TLS 1.0, which GitHub refuses. OR the bit in so a
  # newer protocol already enabled in this process stays enabled.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $repo   = 'valarhq/valar-code-cli'
  $prefix = if ($env:VALAR_PREFIX) { $env:VALAR_PREFIX } else { Join-Path $env:USERPROFILE '.local\bin' }
  $prefix = $prefix.TrimEnd('\')
  # From the environment, not [RuntimeInformation]::OSArchitecture: that .NET call can bind to
  # a facade and return null in Windows PowerShell 5.1. PROCESSOR_ARCHITEW6432 is set when an
  # emulated PowerShell runs on a different native architecture.
  $archRaw = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
  $arch   = switch ($archRaw) {
    'ARM64'  { 'arm64' }
    'AMD64'  { 'amd64' }
    default  { throw "install.ps1: unsupported architecture '$archRaw'" }
  }

  # ---- resolve the release (one API call; none when pinned, as install.sh) ----
  $version = $env:VALAR_VERSION
  if (-not $version) {
    $headers = @{ 'User-Agent' = 'valar-install.ps1'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    try {
      $version = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers $headers).tag_name
    } catch {
      throw "install.ps1: could not resolve a release version ($($_.Exception.Message)); set VALAR_VERSION, or GITHUB_TOKEN to lift the API rate limit"
    }
  }
  $asset = "valar-windows-$arch.exe"
  # Release downloads are unmetered, unlike the API (install.sh uses the same URLs).
  $base  = "https://github.com/$repo/releases/download/$version"
  Write-Host "==> valar $version for windows/$arch"

  $tmp = Join-Path ([IO.Path]::GetTempPath()) "valar-install-$PID"
  New-Item -ItemType Directory -Force $tmp | Out-Null
  try {
    function Get-Asset([string]$name, [switch]$Optional) {
      $out = Join-Path $tmp $name
      try {
        Invoke-WebRequest "$base/$name" -OutFile $out -UseBasicParsing
      } catch {
        if ($Optional) { return $null }
        throw "install.ps1: release $version has no asset '$name' ($($_.Exception.Message))"
      }
      return $out
    }

    # checksums first: a missing entry is found before the binary is transferred.
    $checksums = Get-Asset 'checksums.txt'
    $want = $null
    foreach ($line in Get-Content $checksums) {
      if ($line -match "^([0-9a-fA-F]{64})\s+\*?(?:.*[\\/])?$([regex]::Escape($asset))$") { $want = $Matches[1].ToLower(); break }
    }
    if (-not $want) { throw "install.ps1: no checksum entry for $asset in checksums.txt" }

    # ---- download + verify SHA256 (mandatory, fails closed) ----
    $bin_tmp = Get-Asset $asset
    $got = (Get-FileHash $bin_tmp -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $want) { throw "install.ps1: SHA256 verification FAILED for $asset (want $want, got $got)" }
    Write-Host "    sha256: OK"

    # ---- verify cosign signature (optional) ----
    $bundle = $null
    if (Get-Command cosign -ErrorAction SilentlyContinue) { $bundle = Get-Asset 'checksums.txt.bundle' -Optional }
    if ($bundle) {
      $identity = "https://github.com/valarhq/valar-monorepo/.github/workflows/release-valar-code.yml@refs/tags/$version"
      # cosign reports on stderr even on success; under $ErrorActionPreference=Stop a merged
      # stderr line is a terminating error, so the call runs with Continue and is judged by
      # its exit code alone.
      $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      $cosignOut = & cosign verify-blob --certificate-identity $identity `
          --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' `
          --bundle $bundle $checksums 2>&1
      $cosignRc = $LASTEXITCODE
      $ErrorActionPreference = $prev
      if ($cosignRc -ne 0) { throw "install.ps1: cosign signature verification FAILED`n$($cosignOut -join "`n")" }
      Write-Host "    cosign: OK (provenance verified)"
    } else {
      Write-Host "    cosign: skipped (install cosign to verify provenance; see SECURITY.md)"
    }

    # ---- install (always overwrites $prefix\valar.exe with the resolved version) ----
    New-Item -ItemType Directory -Force $prefix | Out-Null
    $bin = Join-Path $prefix 'valar.exe'
    $prev_version = if (Test-Path $bin) { try { (& $bin --version 2>$null) -join '' } catch { '' } } else { '' }
    # Stage next to the destination so the final rename never crosses volumes.
    $staged = "$bin.new"
    Move-Item $bin_tmp $staged -Force
    # A running exe can't be overwritten but can be renamed aside - the same dance as
    # `valar upgrade`. A stale aside still held by a running process gets a fresh name.
    $old = "$bin.old"
    Remove-Item $old -Force -ErrorAction SilentlyContinue
    if (Test-Path $old) { $old = "$bin.old-$PID" }
    $moved = $false
    if (Test-Path $bin) { Move-Item $bin $old -Force; $moved = $true }
    try {
      Move-Item $staged $bin -Force
    } catch {
      if ($moved) { Move-Item $old $bin -Force } # put the previous binary back
      throw
    }
    Remove-Item $old -Force -ErrorAction SilentlyContinue
    # Integrity was verified above; drop the mark-of-the-web so the first run isn't blocked.
    Unblock-File $bin -ErrorAction SilentlyContinue
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ---- PATH (user scope; no elevation) ----
  # Straight to the registry rather than [Environment]::SetEnvironmentVariable: that API
  # expands %VAR% entries and writes the value back as REG_SZ, silently flattening the
  # default REG_EXPAND_SZ user Path. Read unexpanded, append, write back with the same kind.
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  try {
    $userPath = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $kind = if ($userPath) { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
    $present = ($userPath -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') }) -contains $prefix
    if (-not $present) {
      $key.SetValue('Path', (($userPath.TrimEnd(';') + ";$prefix").TrimStart(';')), $kind)
      # Registry writes do not notify running shells; a user-scope set/delete through .NET does
      # (WM_SETTINGCHANGE), so touch a scratch variable to broadcast.
      [Environment]::SetEnvironmentVariable('VALAR_INSTALL_PATH_UPDATED', '1', 'User')
      [Environment]::SetEnvironmentVariable('VALAR_INSTALL_PATH_UPDATED', $null, 'User')
      Write-Host "    added $prefix to your user PATH (new terminals pick it up)"
    }
  } finally {
    $key.Close()
  }
  if (($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') }) -notcontains $prefix) { $env:Path += ";$prefix" }

  # ---- report ----
  $new_version = ''
  try {
    $new_version = (& $bin --version 2>&1) -join ''
    if ($LASTEXITCODE -ne 0) { $new_version = '' }
  } catch { $new_version = '' }
  if (-not $new_version) {
    Write-Warning "install.ps1: $bin is in place but did not run cleanly; try 'valar --version' from a new shell"
  } elseif ($prev_version -and $prev_version -ne $new_version) {
    Write-Host "    installed: $bin (replaced $prev_version -> $new_version)"
  } else {
    Write-Host "    installed: $bin ($new_version)"
  }
  $onPath = Get-Command valar -ErrorAction SilentlyContinue
  if ($onPath -and $onPath.Source -and ($onPath.Source -ne $bin)) {
    Write-Warning "install.ps1: 'valar' on your PATH resolves to $($onPath.Source), not $bin - the earlier entry shadows this install; remove it or put $prefix first"
  }

  # ---- guided setup ----
  # In a console, run the setup from the binary just installed, one `valar` command per step:
  # sign in, read the organization's installation defaults, then the on-device proxy and quota
  # first when those defaults say so, then pick the tools. `irm | iex` runs this script in the
  # engineer's own console, so each step reads it. The steps call $bin by its full path; the
  # commands printed for the engineer use the bare name.
  $runHint = if ($onPath -and ($onPath.Source -eq $bin)) { 'run:' } else { 'open a new terminal, then run:' }
  $policyRead = $false
  $proxy = ''
  $quotaFirst = ''

  # Prints the setup commands from step $from on. Until the policy is read, the two optional
  # steps carry the condition that decides them; after, only the steps the policy asks for.
  function Write-Steps([string]$from) {
    $listing = $false
    foreach ($s in 'login', 'org-policy', 'proxy', 'quota-first', 'on') {
      if ($s -eq $from) { $listing = $true }
      if (-not $listing) { continue }
      switch ($s) {
        'login'       { Write-Host '      valar login' }
        'org-policy'  { Write-Host '      valar org-policy' }
        'proxy' {
          if (-not $policyRead)  { Write-Host '      valar proxy enable              (only if org-policy printed proxy=on)' }
          elseif ($proxy -eq 'on') { Write-Host '      valar proxy enable' }
        }
        'quota-first' {
          if (-not $policyRead)  { Write-Host '      valar configure --quota-first   (only if org-policy printed quota_first=on)' }
          elseif ($quotaFirst -eq 'on') { Write-Host '      valar configure --quota-first' }
        }
        'on'          { Write-Host '      valar on' }
      }
    }
  }

  # A failed step ends the install with that step's exit code. Nothing after it runs: the
  # remaining steps may depend on it, and a failed proxy step must not leave tools on the
  # direct lane when the organization chose the proxy. Run from a file, the script exits with
  # the code; run through `irm | iex` it returns with $LASTEXITCODE set, since `exit` would
  # close the engineer's console.
  function Stop-Setup([string]$step, [string]$command, [int]$code) {
    Write-Host ''
    Write-Host "==> Setup stopped: '$command' did not finish (exit code $code)."
    if ($step -eq 'proxy') {
      Write-Host '    The on-device proxy needs administrator rights on this machine.'
      Write-Host '    If you cannot give them, ask your IT team to install it.'
    }
    Write-Host "    To finish the setup, $runHint"
    Write-Steps $step
    $global:LASTEXITCODE = $code
    if ($PSCommandPath) { exit $code }
  }

  # A release without the guided setup (no `valar org-policy` or no global `valar on`; v1.1.46
  # and v1.1.47 have the first but not the second) installs exactly as the installer did before
  # the guided setup existed: nothing more is printed.
  # `*> $null` does not silence a native command's stderr in Windows PowerShell 5.1; a pipe does.
  $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    & $bin org-policy --help 2>&1 | Out-Null; $supported = ($LASTEXITCODE -eq 0)
    if ($supported) { & $bin on --help 2>&1 | Out-Null; $supported = ($LASTEXITCODE -eq 0) }
  } catch { $supported = $false } finally { $ErrorActionPreference = $prevPref }
  if (-not $supported) {
    $global:LASTEXITCODE = 0
    return
  }

  Write-Host ''
  if ([Console]::IsInputRedirected) {
    Write-Host "==> No terminal, so the setup did not run. To finish it, $runHint"
    Write-Steps 'login'
    $global:LASTEXITCODE = 0
    return
  }

  Write-Host '==> Setting up valar'
  # Each step runs as a plain statement, not inside a function or a capture, so valar gets this
  # console for its questions. Native stderr must not become a terminating error under
  # $ErrorActionPreference = 'Stop', so each call runs with Continue and is judged by its exit
  # code alone.
  foreach ($step in 'login', 'org-policy', 'proxy', 'quota-first', 'on') {
    $stepArgs = switch ($step) {
      'login'       { , @('login') }
      'org-policy'  { , @('org-policy') }
      'proxy'       { if ($proxy -eq 'on') { , @('proxy', 'enable') } }
      'quota-first' { if ($quotaFirst -eq 'on') { , @('configure', '--quota-first') } }
      'on'          { , @('on') }
    }
    if (-not $stepArgs) { continue }
    $command = "valar $($stepArgs -join ' ')"
    Write-Host ''
    Write-Host "==> $command"
    $ErrorActionPreference = 'Continue'
    if ($step -eq 'org-policy') { $policyOut = & $bin @stepArgs } else { & $bin @stepArgs }
    $rc = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($rc -ne 0) { Stop-Setup $step $command $rc; return }
    if ($step -eq 'org-policy') {
      # key=value lines; keys this script does not know are ignored.
      $policy = ConvertFrom-StringData (($policyOut | Where-Object { $_ -match '^[A-Za-z_]+=' }) -join "`n")
      $proxy = [string]$policy['proxy']
      $quotaFirst = [string]$policy['quota_first']
      if (($proxy -notin 'on', 'off') -or ($quotaFirst -notin 'on', 'off')) {
        Write-Host "install.ps1: 'valar org-policy' did not print proxy=on|off and quota_first=on|off"
        Stop-Setup $step $command 1; return
      }
      $policyRead = $true
      Write-Host "    on-device proxy: $proxy, quota first: $quotaFirst"
    }
  }

  Write-Host ''
  Write-Host "==> valar is set up. For more, $runHint"
  Write-Host '      valar help'
}
