# roja-install

Public distribution point for the **Roja / AI One agent install scripts** — serves
`install.sh` and `install.ps1` at **https://install.getroja.ai** (GitHub Pages, custom
domain). This is the URL the backend install-token mint endpoint hands users in the
install one-liner.

**Why this repo exists:** these two scripts are non-sensitive and must be publicly
downloadable, but the agent **source / KAL action catalog / DSL** is proprietary and
lives in the **private** `rgshepherd21/aione-agent` repo. This repo isolates the public
surface from the IP.

**Keeping in sync:** when `install/install.sh`, `install/install.ps1`,
`install/uninstall.sh`, or `install/uninstall.ps1` change in `aione-agent`, copy them
here and push to `main` — the Pages workflow redeploys.

Source of truth for the scripts: `aione-agent/install/` (private).

## Binary releases

As of 2026-07-01 the agent **release binaries are mirrored to this repo's
GitHub Releases** by aione-agent's release workflow (the source repo is
private, so its assets are not anonymously downloadable). The install
scripts resolve versions and download from `rgshepherd21/roja-install`
releases. Source of truth for build + mirror: `aione-agent/.github/workflows/release.yml`.

## Uninstalling

```
# Linux / macOS (preserves the agent identity + credential vault for reinstall)
curl -sSL https://install.getroja.ai/uninstall.sh | sudo bash

# ... full removal including identity + vault (requires explicit confirmation)
curl -sSL https://install.getroja.ai/uninstall.sh | sudo bash -s -- --purge --yes

# Windows (elevated PowerShell)
iwr -useb https://install.getroja.ai/uninstall.ps1 -OutFile uninstall.ps1; .\uninstall.ps1
```

Uninstalling locally does **not** deregister the agent server-side — revoke it in the
Roja console afterwards (Console -> Devices -> Agents -> Revoke; the script prints the
agent ID).
