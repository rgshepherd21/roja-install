<#
.SYNOPSIS
  AI One agent installer (Windows).

.DESCRIPTION
  Downloads the aione-agent binary for the current architecture from
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
  2026-06-09 — this time to the CANONICAL public production URL, which
  cannot recreate the stale-dev-FQDN hazard.

.PARAMETER Name
  OPTIONAL. Agent display name. Defaults to the machine hostname.

.PARAMETER NoStart
  OPTIONAL. Install the service but don't start it.

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
    [switch]$NoStart
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
        # 404 or other — try the unfiltered list next.
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
Write-Host ">>> Installing aione-agent $Version for windows-$Arch" -ForegroundColor Cyan

# --- paths -----------------------------------------------------------------
$InstallDir  = "C:\Program Files\AIOne\Agent"
$ConfigDir   = "C:\ProgramData\AIOne\Agent"
$DataDir     = "C:\ProgramData\AIOne\Agent\data"
$BinaryName  = "aione-agent-$Version-windows-$Arch.exe"
$BinaryUrl   = "https://github.com/$Repo/releases/download/$Version/$BinaryName"
$ChecksumUrl = "$BinaryUrl.sha256"

# --- download + verify -----------------------------------------------------
$tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "aione-install-$(Get-Random)") -Force
try {
    $binaryPath   = Join-Path $tmp "aione-agent.exe"
    $checksumPath = Join-Path $tmp "aione-agent.exe.sha256"

    Write-Host ">>> Downloading $BinaryName" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $BinaryUrl   -OutFile $binaryPath   -UseBasicParsing
    Invoke-WebRequest -Uri $ChecksumUrl -OutFile $checksumPath -UseBasicParsing

    $expected = (Get-Content $checksumPath -Raw).Split(' ')[0].Trim().ToLower()
    $actual   = (Get-FileHash -Algorithm SHA256 -Path $binaryPath).Hash.ToLower()
    if ($expected -ne $actual) {
        throw "Checksum mismatch: expected $expected, got $actual"
    }
    Write-Host "    ✓ checksum verified" -ForegroundColor Green

    # --- install ---------------------------------------------------------------
    New-Item -ItemType Directory -Path $InstallDir, $ConfigDir, $DataDir -Force | Out-Null
    Move-Item -Force -Path $binaryPath -Destination (Join-Path $InstallDir "aione-agent.exe")

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

log:
  level: info
  pretty: false
"@
    $configContent | Set-Content -Path (Join-Path $ConfigDir "agent.yaml") -Encoding UTF8

    # --- register as a Windows service ------------------------------------
    Write-Host ">>> Installing Windows service" -ForegroundColor Cyan
    $env:AIONE_INSTALL_TOKEN = $Token
    & (Join-Path $InstallDir "aione-agent.exe") `
        -service install `
        -config (Join-Path $ConfigDir "agent.yaml")
    if ($LASTEXITCODE -ne 0) { throw "-service install failed (exit $LASTEXITCODE)" }

    if (-not $NoStart) {
        Start-Service aione-agent
        Start-Sleep -Seconds 2
        $svc = Get-Service aione-agent -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            Write-Host "    ✓ service started" -ForegroundColor Green
        } else {
            Write-Warning "service did not reach Running state; check Windows Event Log (aione-agent source)"
        }
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Remove-Item Env:AIONE_INSTALL_TOKEN -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "✓ aione-agent $Version installed" -ForegroundColor Green
Write-Host "  binary:  $InstallDir\aione-agent.exe"
Write-Host "  config:  $ConfigDir\agent.yaml"
Write-Host "  data:    $DataDir"
Write-Host ""
if (-not $NoStart) {
    Write-Host "Check the Roja chat UI — the new host should appear within 30 s."
} else {
    Write-Host "Service installed but NOT started. Start with: Start-Service aione-agent"
}
