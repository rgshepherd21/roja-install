#!/usr/bin/env bash
# uninstall.sh — Roja agent uninstaller (Linux + macOS)
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

# Removes the Roja agent and, on a host installed before the rename (R51),
# the aione-agent one: whichever names are present.
case "$(uname -s)" in
  Linux)   PREFIXES="/opt /etc /var/lib" ;;
  Darwin)  PREFIXES="/usr/local/opt /usr/local/etc /usr/local/var" ;;
  *)
    echo "ERROR: unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
set -- $PREFIXES
INSTALL_BASE="$1"; CONFIG_BASE="$2"; DATA_BASE="$3"

# The data directories present (identity + vault), Roja first.
DATA_DIRS=""
for name in roja-agent aione-agent; do
  [ -d "${DATA_BASE}/${name}" ] && DATA_DIRS="${DATA_DIRS} ${DATA_BASE}/${name}"
done

# Surface the agent ID before anything is removed (needed for the
# console-side revoke afterwards). registration.json is 0600 root.
AGENT_ID=""
for d in $DATA_DIRS; do
  if [ -f "${d}/registration.json" ]; then
    id="$(sed -n 's/.*"agent_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${d}/registration.json" | head -1)"
    [ -n "$id" ] && AGENT_ID="${AGENT_ID:+${AGENT_ID} }${id}"
  fi
done

# --purge safety: destroying the vault + identity is irreversible.
if [ "$PURGE" -eq 1 ] && [ "$ASSUME_YES" -ne 1 ]; then
  if [ -t 0 ]; then
    printf -- "--purge will DELETE the credential vault and this agent's identity (%s). Type 'purge' to confirm: " "${DATA_DIRS# }"
    read -r answer
    [ "$answer" = "purge" ] || { echo "Aborted."; exit 1; }
  else
    echo "ERROR: --purge in a non-interactive run requires --yes." >&2
    exit 2
  fi
fi

for name in roja-agent aione-agent; do
  INSTALL_DIR="${INSTALL_BASE}/${name}"
  CONFIG_DIR="${CONFIG_BASE}/${name}"

  echo ">>> Stopping service ${name}"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$name" 2>/dev/null || true
  fi

  echo ">>> Deregistering service ${name}"
  # Prefer the binary's own service manager (matches how it was installed) …
  if [ -x "${INSTALL_DIR}/${name}" ]; then
    "${INSTALL_DIR}/${name}" -service uninstall 2>/dev/null || true
  fi
  # … then belt-and-braces manual cleanup. History: a failed uninstall can
  # leave a zombie systemd unit (see internal/service/flock_unix.go), and
  # the binary may already be gone on a broken install — handle both.
  if [ "$(uname -s)" = "Linux" ]; then
    # Remove the drop-ins install.sh added (vault EnvironmentFile, restart
    # policy). The master key the vault one references lives in the data
    # dir, so it follows the --purge rule with the rest of the vault.
    rm -rf "/etc/systemd/system/${name}.service.d"
    if [ -f "/etc/systemd/system/${name}.service" ]; then
      systemctl disable "$name" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/${name}.service"
      systemctl daemon-reload
    fi
  else
    for plist in /Library/LaunchDaemons/*"${name}"*.plist; do
      [ -e "$plist" ] || continue
      launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"
    done
  fi

  if [ -d "$INSTALL_DIR" ]; then
    echo ">>> Removing binary (${INSTALL_DIR})"
    rm -rf "${INSTALL_DIR}"
  fi
  if [ -d "$CONFIG_DIR" ]; then
    echo ">>> Removing config (${CONFIG_DIR})"
    rm -rf "${CONFIG_DIR}"
  fi
done

for d in $DATA_DIRS; do
  if [ "$PURGE" -eq 1 ]; then
    echo ">>> Purging data dir (${d}) — identity + vault deleted"
    rm -rf "${d}"
  else
    echo ">>> PRESERVED data dir (${d}): agent identity, credential"
    echo "    vault, cached registry. Reinstalling resumes this agent."
    echo "    To remove it too, re-run with: --purge"
  fi
done

echo ""
echo "=== Roja agent uninstalled ==="
if [ -n "$AGENT_ID" ]; then
  echo "Final step (server side): revoke this agent in the Roja console"
  echo "  Console -> Devices -> Agents -> Revoke: ${AGENT_ID}"
else
  echo "Final step (server side): revoke this agent in the Roja console"
  echo "  (agent ID unavailable locally$( [ "$PURGE" -eq 1 ] && echo " — purged" ); find it under Console -> Devices -> Agents)"
fi
