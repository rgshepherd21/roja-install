# roja-install

Public distribution point for the **Roja / AI One agent install scripts** — serves
`install.sh` and `install.ps1` at **https://install.getroja.ai** (GitHub Pages, custom
domain). This is the URL the backend install-token mint endpoint hands users in the
install one-liner.

**Why this repo exists:** these two scripts are non-sensitive and must be publicly
downloadable, but the agent **source / KAL action catalog / DSL** is proprietary and
lives in the **private** `rgshepherd21/aione-agent` repo. This repo isolates the public
surface from the IP.

**Keeping in sync:** when `install/install.sh` or `install/install.ps1` change in
`aione-agent`, copy them here and push to `main` — the Pages workflow redeploys.

Source of truth for the scripts: `aione-agent/install/` (private).
