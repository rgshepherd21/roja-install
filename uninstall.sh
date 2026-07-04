#!/usr/bin/env bash
# uninstall.sh — AI One agent uninstaller (Linux + macOS)
#
# Usage:
#   curl -sSL https://install.getroja.ai/uninstall.sh | sudo bash
#   curl -sSL https://install.getroja.ai/uninstall.sh | sudo bash -s -- --purge --yes
#
# Flags:
#   --purge   ALSO delete the data directory. The data dir holds this
#             agent's registered identity — mTLS client cert/key, the
#             encrypted credential vault, and the cached signed registry.
#             Without --purge those are PRESERVED, so a later reinstall
#             resumes the SAME agent (no new install token, vault intact).
#             With --purge, reconnecting ever again requires re-enrolling
#             with a fresh install token.
#   --yes|-y  Required with --purge when running non-interactively
#             (e.g. curl | bash): deleting credentials needs explicit
#             intent. Interactive runs prompt instead.
#
# What this does NOT do: deregister the agent from the Roja backend. The
# server-side registration (and its mTLS cert) remain until revoked in
# the console — after uninstalling, go to Console -> Devices -> Agents ->
# Revoke. This script prints the agent ID to make that easy.
#
# Mirrors install.sh paths exactly; see that script for their history.
set -euo pipefail

PURGE=0; ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --purge)   PURGE=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help)
      echo "Usage: uninstall.sh [--purge] [--yes]"
      echo "  --purge  also delete the data dir (agent identity + vault)"
      echo "  --yes    confirm --purge for non-interactive runs"
      exit 0 ;;
    *) echo "ERROR: unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (sudo)." >&2
  exit 1
fi

case "$(uname -s)" in
  Linux)
    INSTALL_DIR="/opt/aione-agent"
    CONFIG_DIR="/etc/aione-agent"
    DATA_DIR="/var/lib/aione-agent"
    ;;
  Darwin)
    INSTALL_DIR="/usr/local/opt/aione-agent"
    CONFIG_DIR="/usr/local/etc/aione-agent"
    DATA_DIR="/usr/local/var/aione-agent"
    ;;
  *)
    echo "ERROR: unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

# Surface the agent ID before anything is removed (needed for the
# console-side revoke afterwards). registration.json is 0600 root.
AGENT_ID=""
if [ -f "${DATA_DIR}/registration.json" ]; then
  AGENT_ID="$(sed -n 's/.*"agent_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${DATA_DIR}/registration.json" | head -1)"
fi

# --purge safety: destroying the vault + identity is irreversible.
if [ "$PURGE" -eq 1 ] && [ "$ASSUME_YES" -ne 1 ]; then
  if [ -t 0 ]; then
    printf -- "--purge will DELETE the credential vault and this agent's identity (%s). Type 'purge' to confirm: " "${DATA_DIR}"
    read -r answer
    [ "$answer" = "purge" ] || { echo "Aborted."; exit 1; }
  else
    echo "ERROR: --purge in a non-interactive run requires --yes." >&2
    exit 2
  fi
fi

echo ">>> Stopping service"
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop aione-agent 2>/dev/null || true
fi

echo ">>> Deregistering service"
# Prefer the binary's own service manager (matches how it was installed) …
if [ -x "${INSTALL_DIR}/aione-agent" ]; then
  "${INSTALL_DIR}/aione-agent" -service uninstall 2>/dev/null || true
fi
# … then belt-and-braces manual cleanup. History: a failed uninstall can
# leave a zombie systemd unit (see internal/service/flock_unix.go), and
# the binary may already be gone on a broken install — handle both.
if [ "$(uname -s)" = "Linux" ]; then
  if [ -f /etc/systemd/system/aione-agent.service ]; then
    systemctl disable aione-agent >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/aione-agent.service
    systemctl daemon-reload
  fi
else
  for plist in /Library/LaunchDaemons/*aione-agent*.plist; do
    [ -e "$plist" ] || continue
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
  done
fi

echo ">>> Removing binary (${INSTALL_DIR})"
rm -rf "${INSTALL_DIR}"

echo ">>> Removing config (${CONFIG_DIR})"
rm -rf "${CONFIG_DIR}"

if [ "$PURGE" -eq 1 ]; then
  echo ">>> Purging data dir (${DATA_DIR}) — identity + vault deleted"
  rm -rf "${DATA_DIR}"
else
  echo ">>> PRESERVED data dir (${DATA_DIR}): agent identity, credential"
  echo "    vault, cached registry. Reinstalling resumes this agent."
  echo "    To remove it too, re-run with: --purge"
fi

echo ""
echo "=== AI One agent uninstalled ==="
if [ -n "$AGENT_ID" ]; then
  echo "Final step (server side): revoke this agent in the Roja console"
  echo "  Console -> Devices -> Agents -> Revoke: ${AGENT_ID}"
else
  echo "Final step (server side): revoke this agent in the Roja console"
  echo "  (agent ID unavailable locally$( [ "$PURGE" -eq 1 ] && echo " — purged" ); find it under Console -> Devices -> Agents)"
fi
