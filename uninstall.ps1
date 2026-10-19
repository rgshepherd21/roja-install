# uninstall.ps1 - Roja agent uninstaller (Windows)
#
# Usage (elevated PowerShell):
#   iwr -useb https://install.getroja.ai/uninstall.ps1 -OutFile uninstall.ps1; .\uninstall.ps1
#   .\uninstall.ps1 -Purge -Yes
#
# Default behavior removes the service registration, the binary, and the
# config file, but PRESERVES the data directory: it holds this agent's
# registered identity - mTLS client cert/key (DPAPI-wrapped vault KEK),
# the encrypted credential vault, and the cached signed registry - so a
# later reinstall resumes the SAME agent without a new install token.
#
#   -Purge   also delete the data directory (identity + vault). Requires
#            -Yes when running non-interactively; prompts otherwise.
#   -Yes     confirm -Purge without a prompt.
#
# What this does NOT do: deregister the agent from the Roja backend.
# After uninstalling, revoke the agent in the console:
#   Console -> Devices -> Agents -> Revoke  (agent ID printed below).
#
# Mirrors install.ps1 paths exactly (CR-8 lineage).
[CmdletBinding()]
param(
    [switch]$Purge,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'

# The Roja install and, on a host installed before the rename (R51), the
# aione-agent / AIOne one: whichever are present.
$Installs = @(
    @{ Service = "roja-agent";  InstallDir = "C:\Program Files\Roja\Agent";  ConfigDir = "C:\ProgramData\Roja\Agent" },
    @{ Service = "aione-agent"; InstallDir = "C:\Program Files\AIOne\Agent"; ConfigDir = "C:\ProgramData\AIOne\Agent" }
)

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Must run from an elevated (Administrator) PowerShell."
}

# The data directories present (identity + vault), Roja first.
$DataDirs = @($Installs | ForEach-Object { Join-Path $_.ConfigDir "data" } | Where-Object { Test-Path $_ })

# Capture the agent ID before anything is removed (needed for the
# console-side revoke afterwards).
$AgentIds = @()
foreach ($d in $DataDirs) {
    $regFile = Join-Path $d "registration.json"
    if (Test-Path $regFile) {
        try { $AgentIds += (Get-Content $regFile -Raw | ConvertFrom-Json).agent_id } catch {}
    }
}
$AgentId = ($AgentIds | Where-Object { $_ }) -join ", "

if ($Purge -and -not $Yes) {
    if ([Environment]::UserInteractive) {
        $answer = Read-Host "-Purge will DELETE the credential vault and this agent's identity ($($DataDirs -join ', ')). Type 'purge' to confirm"
        if ($answer -ne 'purge') { Write-Host "Aborted."; exit 1 }
    } else {
        throw "-Purge in a non-interactive run requires -Yes."
    }
}

foreach ($i in $Installs) {
    $ServiceName = $i.Service
    $InstallDir  = $i.InstallDir
    $ConfigDir   = $i.ConfigDir

    Write-Host ">>> Stopping service $ServiceName" -ForegroundColor Cyan
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue

    Write-Host ">>> Deregistering service $ServiceName" -ForegroundColor Cyan
    # Prefer the binary's own service manager (matches how it was installed) ...
    $exe = Join-Path $InstallDir "$ServiceName.exe"
    if (Test-Path $exe) {
        & $exe -service uninstall 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host ">>> binary -service uninstall failed; falling back to sc.exe" -ForegroundColor Yellow }
    }
    # ... then belt-and-braces: a broken install may have lost the binary but
    # kept the service registration.
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        sc.exe delete $ServiceName | Out-Null
    }

    if (Test-Path $InstallDir) {
        Write-Host ">>> Removing binary ($InstallDir)" -ForegroundColor Cyan
        Remove-Item -Recurse -Force $InstallDir
    }

    $cfg = Join-Path $ConfigDir "agent.yaml"
    if (Test-Path $cfg) {
        Write-Host ">>> Removing config ($cfg)" -ForegroundColor Cyan
        Remove-Item -Force $cfg
    }

    $data = Join-Path $ConfigDir "data"
    if ($Purge) {
        if (Test-Path $ConfigDir) {
            Write-Host ">>> Purging $ConfigDir (data dir: identity + vault deleted)" -ForegroundColor Yellow
            Remove-Item -Recurse -Force $ConfigDir
        }
    } elseif (Test-Path $data) {
        Write-Host ">>> PRESERVED data dir ($data): agent identity, credential" -ForegroundColor Green
        Write-Host "    vault, cached registry. Reinstalling resumes this agent." -ForegroundColor Green
        Write-Host "    To remove it too, re-run with: -Purge" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "=== Roja agent uninstalled ===" -ForegroundColor Green
Write-Host "Final step (server side): revoke this agent in the Roja console"
if ($AgentId) {
    Write-Host "  Console -> Devices -> Agents -> Revoke: $AgentId"
} else {
    Write-Host "  (agent ID unavailable locally; find it under Console -> Devices -> Agents)"
}
