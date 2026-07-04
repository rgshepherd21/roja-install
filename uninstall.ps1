# uninstall.ps1 — AI One agent uninstaller (Windows)
#
# Usage (elevated PowerShell):
#   iwr -useb https://install.getroja.ai/uninstall.ps1 -OutFile uninstall.ps1; .\uninstall.ps1
#   .\uninstall.ps1 -Purge -Yes
#
# Default behavior removes the service registration, the binary, and the
# config file, but PRESERVES the data directory: it holds this agent's
# registered identity — mTLS client cert/key (DPAPI-wrapped vault KEK),
# the encrypted credential vault, and the cached signed registry — so a
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

$InstallDir = "C:\Program Files\AIOne\Agent"
$ConfigDir  = "C:\ProgramData\AIOne\Agent"
$DataDir    = "C:\ProgramData\AIOne\Agent\data"
$ServiceName = "aione-agent"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Must run from an elevated (Administrator) PowerShell."
}

# Capture the agent ID before anything is removed (needed for the
# console-side revoke afterwards).
$AgentId = $null
$regFile = Join-Path $DataDir "registration.json"
if (Test-Path $regFile) {
    try { $AgentId = (Get-Content $regFile -Raw | ConvertFrom-Json).agent_id } catch {}
}

if ($Purge -and -not $Yes) {
    if ([Environment]::UserInteractive) {
        $answer = Read-Host "-Purge will DELETE the credential vault and this agent's identity ($DataDir). Type 'purge' to confirm"
        if ($answer -ne 'purge') { Write-Host "Aborted."; exit 1 }
    } else {
        throw "-Purge in a non-interactive run requires -Yes."
    }
}

Write-Host ">>> Stopping service" -ForegroundColor Cyan
Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue

Write-Host ">>> Deregistering service" -ForegroundColor Cyan
# Prefer the binary's own service manager (matches how it was installed) ...
$exe = Join-Path $InstallDir "aione-agent.exe"
if (Test-Path $exe) {
    & $exe -service uninstall 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host ">>> binary -service uninstall failed; falling back to sc.exe" -ForegroundColor Yellow }
}
# ... then belt-and-braces: a broken install may have lost the binary but
# kept the service registration.
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    sc.exe delete $ServiceName | Out-Null
}

Write-Host ">>> Removing binary ($InstallDir)" -ForegroundColor Cyan
if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }

Write-Host ">>> Removing config ($ConfigDir\agent.yaml)" -ForegroundColor Cyan
$cfg = Join-Path $ConfigDir "agent.yaml"
if (Test-Path $cfg) { Remove-Item -Force $cfg }

if ($Purge) {
    Write-Host ">>> Purging data dir ($DataDir) - identity + vault deleted" -ForegroundColor Yellow
    if (Test-Path $ConfigDir) { Remove-Item -Recurse -Force $ConfigDir }
} else {
    Write-Host ">>> PRESERVED data dir ($DataDir): agent identity, credential" -ForegroundColor Green
    Write-Host "    vault, cached registry. Reinstalling resumes this agent." -ForegroundColor Green
    Write-Host "    To remove it too, re-run with: -Purge" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== AI One agent uninstalled ===" -ForegroundColor Green
Write-Host "Final step (server side): revoke this agent in the Roja console"
if ($AgentId) {
    Write-Host "  Console -> Devices -> Agents -> Revoke: $AgentId"
} else {
    Write-Host "  (agent ID unavailable locally; find it under Console -> Devices -> Agents)"
}
