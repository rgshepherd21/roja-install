<#
.SYNOPSIS
  Roja agent installer (Windows).

.DESCRIPTION
  Downloads the roja-agent binary for the current architecture from
  GitHub Releases, verifies its SHA-256 checksum, writes a config, and
  installs it as a Windows service via the agent's built-in installer.

.PARAMETER Token
  REQUIRED. Install token from the Roja chat UI.

.PARAMETER Version
  OPTIONAL. Release tag to install (e.g. v0.1.0). Defaults to latest.

.PARAMETER Backend
  OPTIONAL. Backend API base URL. Defaults to the Roja AGENT ingress
  plane (https://agents.getroja.ai), separate from the browser/chat API
  plane (https://api.getroja.ai). The chat UI's copy-paste install
  one-liner still includes it explicitly; only pass it manually for
  dev / on-prem / split-ingress installs.
  History: OPTIONAL before 2026-05-17 with a hardcoded default pointing
  at the dev tenant (hazardous), then REQUIRED, then defaulted again on
  2026-06-09 - this time to the CANONICAL public production URL, which
  cannot recreate the stale-dev-FQDN hazard.

.PARAMETER Name
  OPTIONAL. Agent display name. Defaults to the machine hostname.

.PARAMETER NoStart
  OPTIONAL. Install the service but don't start it.

.PARAMETER Syslog
  OPTIONAL. Enable the embedded syslog receiver on udp/514 so network
  devices pointed at this host with `logging host <ip>` produce telemetry
  events. Off by default: it claims a privileged port, and most agent
  hosts are not a device's syslog target. (N1-A) The generated config now
  always writes an explicit telemetry.syslog block - previously the block
  was absent entirely, so the collector was unreachable by configuration
  alone.

.EXAMPLE
  iex "& { $(irm https://install.getroja.ai/install.ps1) } -Token <tok>"

.EXAMPLE
  # Dev / on-prem install against a non-production backend:
  iex "& { $(irm https://install.getroja.ai/install.ps1) } -Token <tok> -Backend https://api.dev.example.com"
#>
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Token,
    [string]$Version = "",
    [string]$Backend = "https://agents.getroja.ai",
    [string]$Name = $env:COMPUTERNAME,
    [switch]$NoStart,
    [switch]$Syslog
)

Write-Host ">>> Backend: $Backend"
if (-not $Backend.StartsWith("https://")) {
    Write-Error "ERROR: -Backend must be an https:// URL, got: $Backend"
    exit 2
}

$ErrorActionPreference = "Stop"
$Repo = "rgshepherd21/roja-install"   # public distribution repo (binaries mirrored on release)

# --- arch detection --------------------------------------------------------
$Arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { "amd64" }
    "ARM64" { "arm64" }
    default { throw "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
}

# --- resolve version -------------------------------------------------------
# /releases/latest returns 404 for repos whose only release is a prerelease
# (tag with a dash). Fall through to /releases (unfiltered) and take the
# newest tag when /latest misses.
if (-not $Version) {
    try {
        $latest = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
        $Version = $latest.tag_name
    } catch {
        # 404 or other - try the unfiltered list next.
    }
    if (-not $Version) {
        try {
            $all = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases"
            if ($all -and $all[0]) { $Version = $all[0].tag_name }
        } catch {
            throw "Could not resolve version from GitHub API: $_"
        }
    }
    if (-not $Version) { throw "GitHub returned no releases" }
}
# Names (R51: the agent is Roja). $Legacy is the pre-R51 name: a host
# installed before the rename has the aione-agent service and AIOne
# directories, and this script replaces that install (see below).
$Agent  = "roja-agent"
$Legacy = "aione-agent"

Write-Host ">>> Installing $Agent $Version for windows-$Arch" -ForegroundColor Cyan

# --- paths -----------------------------------------------------------------
$InstallDir        = "C:\Program Files\Roja\Agent"
$ConfigDir         = "C:\ProgramData\Roja\Agent"
$DataDir           = "C:\ProgramData\Roja\Agent\data"
$LegacyInstallDir  = "C:\Program Files\AIOne\Agent"
$LegacyConfigDir   = "C:\ProgramData\AIOne\Agent"
$LegacyDataDir     = "C:\ProgramData\AIOne\Agent\data"

# A pre-R51 host keeps its data directory where it is. It holds the agent's
# registered identity and its credential vault, and the vault's DPAPI
# entropy is bound to the directory's path: moving it would lock the vault.
if (-not (Test-Path $DataDir) -and (Test-Path $LegacyDataDir)) {
    $DataDir = $LegacyDataDir
}

# Release assets are roja-agent-<version>-windows-<arch>.exe from R51 on. A
# release before R51 has only aione-agent assets and a binary that expects
# the AIOne paths and service, so this installer refuses it (below).
$ReleaseUrl  = "https://github.com/$Repo/releases/download/$Version"
$BinaryName  = "$Agent-$Version-windows-$Arch.exe"

# --- download + verify -----------------------------------------------------
$tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "roja-install-$(Get-Random)") -Force
try {
    $binaryPath   = Join-Path $tmp "$Agent.exe"
    $checksumPath = Join-Path $tmp "$Agent.exe.sha256"

    Write-Host ">>> Downloading $BinaryName" -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri "$ReleaseUrl/$BinaryName" -OutFile $binaryPath -UseBasicParsing
    } catch {
        throw ("Could not download $BinaryName from $ReleaseUrl. A release before R51 has no " +
               "$Agent binary (it predates the Roja rename) and needs the installer from its " +
               "own era. Omit -Version to install the latest release.")
    }
    Invoke-WebRequest -Uri "$ReleaseUrl/$BinaryName.sha256" -OutFile $checksumPath -UseBasicParsing

    $expected = (Get-Content $checksumPath -Raw).Split(' ')[0].Trim().ToLower()
    $actual   = (Get-FileHash -Algorithm SHA256 -Path $binaryPath).Hash.ToLower()
    if ($expected -ne $actual) {
        throw "Checksum mismatch: expected $expected, got $actual"
    }
    Write-Host "    OK: checksum verified" -ForegroundColor Green

    # --- replace any existing install (idempotent re-run, CR-8) -----------
    # Deliberately AFTER download + checksum: a failed download must never
    # take down a working agent. Mirrors install.sh's #79 pattern: stop the
    # running service so Move-Item can replace the locked binary. Config is
    # regenerated from this run's flags; DataDir (registered identity: mTLS
    # key, action secret) and the service registration are preserved.
    $existingSvc = Get-Service -Name $Agent -ErrorAction SilentlyContinue
    if ($existingSvc) {
        Write-Host ">>> Existing install detected - stopping and replacing it" -ForegroundColor Cyan
        if ($existingSvc.Status -ne "Stopped") {
            Stop-Service -Name $Agent -Force
        }
        # The SCM can keep the image file mapped briefly after Stopped.
        Start-Sleep -Seconds 2
    }

    # A pre-R51 install is replaced by the Roja one: its service is removed
    # (the Roja service is registered below), and so are its binary and its
    # config. Its data directory stays (see "paths" above).
    $legacySvc = Get-Service -Name $Legacy -ErrorAction SilentlyContinue
    if ($legacySvc) {
        Write-Host ">>> Pre-rename install detected ($Legacy) - replacing it" -ForegroundColor Cyan
        if ($legacySvc.Status -ne "Stopped") {
            Stop-Service -Name $Legacy -Force
        }
        # The legacy binary's own uninstall also removes its event-log
        # source; sc.exe is the fallback when the binary is gone.
        $legacyExe = Join-Path $LegacyInstallDir "$Legacy.exe"
        if (Test-Path $legacyExe) { & $legacyExe -service uninstall 2>$null }
        if (Get-Service -Name $Legacy -ErrorAction SilentlyContinue) {
            & sc.exe delete $Legacy | Out-Null
        }
        Start-Sleep -Seconds 2
    }
    if (Test-Path $LegacyInstallDir) {
        Remove-Item -Recurse -Force $LegacyInstallDir -ErrorAction SilentlyContinue
    }
    Remove-Item -Force (Join-Path $LegacyConfigDir "agent.yaml") -ErrorAction SilentlyContinue

    # --- install ---------------------------------------------------------------
    New-Item -ItemType Directory -Path $InstallDir, $ConfigDir, $DataDir -Force | Out-Null

    # Lock down C:\ProgramData\Roja\Agent (CR-8). ProgramData's inherited
    # defaults let ordinary local Users read agent.yaml (install token) and
    # data\ (mTLS key + credential vault). Break inheritance and grant only
    # SYSTEM + Administrators; a new DataDir is a child, so the (OI)(CI) ACEs
    # propagate to it. SIDs instead of names so localized Windows (no
    # "Administrators" group name) doesn't break the install:
    # S-1-5-18 = SYSTEM, S-1-5-32-544 = Administrators.
    & icacls $ConfigDir /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed to restrict $ConfigDir (exit $LASTEXITCODE)" }
    # On a pre-R51 host the data dir is the legacy one, outside $ConfigDir:
    # restrict it the same way (it was, by the old installer; this keeps it so).
    if ($DataDir -eq $LegacyDataDir) {
        & icacls $LegacyConfigDir /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed to restrict $LegacyConfigDir (exit $LASTEXITCODE)" }
    }

    Move-Item -Force -Path $binaryPath -Destination (Join-Path $InstallDir "$Agent.exe")

    # Write config. The install token is written directly: the agent runs
    # as a LocalSystem service and would not inherit a transient env var set
    # only in this installer process, so env-substitution at first run never
    # resolves (agent fatals `install_token is required`). The token is
    # single-use (exchanged for the agent identity on first registration).
    $configContent = @"
agent:
  name: "$Name"
  install_token: "$Token"
  data_dir: "$($DataDir -replace '\\', '\\\\')"
  heartbeat: 5s

vault:
  backend: sqlite

api:
  base_url: $Backend
  timeout: 30s
  retry_max: 5
  retry_delay: 5s

transport:
  insecure_skip_verify: false

# N1-A: written unconditionally, enabled or not. The block being ABSENT
# was the original fault - config.defaults() left SyslogConfig at its zero
# value, so there was no supported way to turn the receiver on short of
# hand-editing this file, and setting enabled: true without udp_addr bound
# nothing while still reporting the collector healthy.
#
# The Windows service runs as LocalSystem, so binding udp/514 succeeds;
# the host firewall still needs an inbound allow rule for it.
telemetry:
  syslog:
    enabled: $($Syslog.IsPresent.ToString().ToLower())
    udp_addr: "0.0.0.0:514"

# U-1 (2026-07-31): written unconditionally, same reasoning as the syslog
# block above. UpdaterConfig.Enabled is NOT set in config.defaults() - only
# Channel, Interval and RequireSigned are - so it takes Go's zero value,
# false. With the block absent, the periodic poll never runs and the console
# Update button logs "self_update requested but updater disabled in config;
# ignoring" and spins forever.
#
# Only `enabled` is specified: config.Load() applies YAML over defaults(),
# so channel/interval/require_signed keep stable / 6h / true.
#
# NOTE (Windows-specific, still open): the kardianos Windows service path
# relies on SCM recovery actions, which - like systemd's Restart=on-failure
# - only fire on an ABNORMAL exit. The updater exits zero deliberately, so
# a Windows agent may swap its binary successfully and then stay stopped.
# The Linux side is fixed via a systemd drop-in in install.sh; the Windows
# equivalent (sc.exe failure/failureflag) is NOT yet wired.
updater:
  enabled: true

log:
  level: info
  pretty: false
"@
    $configContent | Set-Content -Path (Join-Path $ConfigDir "agent.yaml") -Encoding UTF8

    # --- register as a Windows service ------------------------------------
    # Re-registering an existing service fails ("service already exists"),
    # so only run '-service install' on first install (CR-8 idempotency).
    if (-not $existingSvc) {
        Write-Host ">>> Installing Windows service" -ForegroundColor Cyan
        $env:ROJA_INSTALL_TOKEN = $Token
        & (Join-Path $InstallDir "$Agent.exe") `
            -service install `
            -config (Join-Path $ConfigDir "agent.yaml")
        if ($LASTEXITCODE -ne 0) { throw "-service install failed (exit $LASTEXITCODE)" }
    } else {
        Write-Host ">>> Service already registered - skipping -service install" -ForegroundColor Cyan
    }

    if (-not $NoStart) {
        Start-Service $Agent
        Start-Sleep -Seconds 2
        $svc = Get-Service $Agent -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            Write-Host "    OK: service started" -ForegroundColor Green
        } else {
            Write-Warning "service did not reach Running state; check Windows Event Log ($Agent source)"
        }
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Remove-Item Env:ROJA_INSTALL_TOKEN -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "OK: $Agent $Version installed" -ForegroundColor Green
Write-Host "  binary:  $InstallDir\$Agent.exe"
Write-Host "  config:  $ConfigDir\agent.yaml"
Write-Host "  data:    $DataDir"
Write-Host ""
if (-not $NoStart) {
    Write-Host "Check the Roja chat UI - the new host should appear within 30 s."
} else {
    Write-Host "Service installed but NOT started. Start with: Start-Service $Agent"
}
