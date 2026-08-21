#!/usr/bin/env bash
# install.sh — AI One agent installer (Linux + macOS)
#
# Usage:
#   curl -sSL https://install.getroja.ai/install.sh | sudo bash -s -- \
#       --token=<tok> --backend=<url>
#
# Flags:
#   --token=<str>        REQUIRED. Install token from the Roja chat UI.
#   --backend=<url>      OPTIONAL. Backend API base URL. Defaults to the
#                        Roja AGENT ingress plane (https://agents.getroja.ai),
#                        which is SEPARATE from the browser/chat API plane
#                        (https://api.getroja.ai, client-cert 'ignore').
#                        The chat UI's copy-paste install one-liner still
#                        includes it explicitly; only set it manually for
#                        dev / on-prem / split-ingress installs.
#   --version=<vX.Y.Z>   OPTIONAL. Defaults to the latest release.
#   --name=<str>         OPTIONAL. Defaults to the machine hostname.
#   --no-start           OPTIONAL. Install the service but don't start it.
#   --syslog             OPTIONAL. Enable the embedded syslog receiver on
#                        udp/514 so network devices pointed at this host
#                        with `logging host <ip>` produce telemetry events.
#                        Off by default: it claims a privileged port, and
#                        most agent hosts are not a device's syslog target.
#                        (N1-A) The generated config now always writes an
#                        explicit telemetry.syslog block — previously the
#                        block was absent entirely, so the collector was
#                        unreachable by configuration alone.
#
# Exits non-zero on any failure; safe to re-run (idempotent installs).
#
# History: re-running against an existing install used to fail with the
# service manager's "Init already exists" (#79); since 2026-06-11 the
# installer stops + replaces an existing unit in place (config and the
# agent's registered identity in DATA_DIR are preserved), so the re-run
# promise below actually holds.
#
# History: --backend was OPTIONAL before 2026-05-17 with a hardcoded
# default pointing at Ryan's dev tenant — a customer copying a malformed
# one-liner could have silently routed their agent to the wrong backend,
# so it was made REQUIRED. On 2026-06-09, with api.getroja.ai live as the
# stable public production URL, the default was reinstated pointing at
# the CANONICAL backend (never a dev tenant). The original hazard — a
# stale dev FQDN baked into the script — cannot recur with a brand-domain
# default, and the mint endpoint still injects --backend explicitly.
#
# 2026-06-13 (RJ-10/#40): the agent ingress was split onto its own
# hostname (agents.getroja.ai, client-cert 'accept' for mTLS) so the
# browser/chat plane (api.getroja.ai) could flip to client-cert 'ignore'
# and stop popping a cert-selection dialog for enterprise users. The
# default below now points at the AGENT plane.

set -euo pipefail

# --- defaults ---------------------------------------------------------------
TOKEN=""
VERSION=""
BACKEND="https://agents.getroja.ai"
NAME="$(hostname)"
NO_START=false
SYSLOG_ENABLED=false
REPO="rgshepherd21/roja-install"   # public distribution repo (binaries mirrored on release)

# --- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --token=*)   TOKEN="${1#*=}";   shift ;;
        --token)     TOKEN="$2";        shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --version)   VERSION="$2";      shift 2 ;;
        --backend=*) BACKEND="${1#*=}"; shift ;;
        --backend)   BACKEND="$2";      shift 2 ;;
        --name=*)    NAME="${1#*=}";    shift ;;
        --name)      NAME="$2";         shift 2 ;;
        --no-start)  NO_START=true;     shift ;;
        --syslog)    SYSLOG_ENABLED=true; shift ;;
        -h|--help)
            # Range anchored on CONTENT, not a line number. The flags
            # block above grows; a hardcoded end line silently drops the
            # newest flags from --help without anyone noticing. As of
            # 2026-07-27 '2,16p' was cutting off inside the --backend
            # paragraph, hiding --version, --name, --no-start entirely --
            # and would have hidden --syslog too.
            sed -n '2,/^# Exits non-zero/p' "$0"; exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$TOKEN" ]      || { echo "ERROR: --token is required" >&2; exit 2; }
echo ">>> Backend: ${BACKEND}"
case "$BACKEND" in
    https://*) ;;  # only accept https — the agent enforces TLS and the
                   # install token is sensitive enough that http would
                   # leak it on the wire to the registration endpoint.
    *)
        echo "ERROR: --backend must be an https:// URL, got: $BACKEND" >&2
        exit 2
        ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)" >&2; exit 2; }

# --- OS + arch detection ----------------------------------------------------
case "$(uname -s)" in
    Linux)  OS="linux" ;;
    Darwin) OS="darwin" ;;
    *)      echo "ERROR: unsupported OS: $(uname -s)" >&2; exit 2 ;;
esac
case "$(uname -m)" in
    x86_64)          ARCH="amd64" ;;
    aarch64|arm64)   ARCH="arm64" ;;
    *)               echo "ERROR: unsupported arch: $(uname -m)" >&2; exit 2 ;;
esac

# --- resolve version --------------------------------------------------------
# GitHub's /releases/latest endpoint returns 404 for repos whose only release
# is a prerelease (tag with a dash like v0.0.1-alpha.1). During alpha we
# frequently ship only prereleases, so fall through to the unfiltered
# /releases endpoint and take the newest tag when /latest misses.
if [ -z "$VERSION" ]; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
        | grep '"tag_name":' | head -1 | cut -d'"' -f4 || true)"
    if [ -z "$VERSION" ]; then
        VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases" \
            | grep '"tag_name":' | head -1 | cut -d'"' -f4)"
    fi
    [ -n "$VERSION" ] || { echo "ERROR: could not resolve a version from GitHub API (no releases?)" >&2; exit 1; }
fi

echo ">>> Installing aione-agent ${VERSION} for ${OS}-${ARCH}"

# --- paths ------------------------------------------------------------------
if [ "$OS" = "linux" ]; then
    INSTALL_DIR="/opt/aione-agent"
    CONFIG_DIR="/etc/aione-agent"
    DATA_DIR="/var/lib/aione-agent"
else
    INSTALL_DIR="/usr/local/opt/aione-agent"
    CONFIG_DIR="/usr/local/etc/aione-agent"
    DATA_DIR="/usr/local/var/aione-agent"
fi

BINARY_NAME="aione-agent-${VERSION}-${OS}-${ARCH}"
BINARY_URL="https://github.com/${REPO}/releases/download/${VERSION}/${BINARY_NAME}"
CHECKSUM_URL="${BINARY_URL}.sha256"

# --- download + verify ------------------------------------------------------
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo ">>> Downloading ${BINARY_NAME}"
curl -fsSL -o "${TMPDIR}/agent" "$BINARY_URL"
curl -fsSL -o "${TMPDIR}/agent.sha256" "$CHECKSUM_URL"

EXPECTED="$(awk '{print $1}' "${TMPDIR}/agent.sha256")"
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "${TMPDIR}/agent" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "${TMPDIR}/agent" | awk '{print $1}')"
else
    echo "ERROR: neither sha256sum nor shasum available" >&2; exit 1
fi
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "ERROR: checksum mismatch" >&2
    echo "  expected: $EXPECTED" >&2
    echo "  actual:   $ACTUAL" >&2
    exit 1
fi
echo "    ✓ checksum verified"

# macOS quarantine clear (unsigned alpha binaries get flagged otherwise)
if [ "$OS" = "darwin" ]; then
    xattr -rd com.apple.quarantine "${TMPDIR}/agent" 2>/dev/null || true
fi

# --- replace any existing install (idempotent re-run, #79) -------------------
# Deliberately placed AFTER download + checksum: a failed download must never
# take down a working agent. Stops the running service and removes the old
# unit file so the fresh '-service install' below cannot hit "Init already
# exists". CONFIG_DIR and DATA_DIR are left in place — DATA_DIR holds the
# agent's registered identity (mTLS key, action secret), which survives
# re-installs; the config is regenerated from this run's flags.
if [ "$OS" = "linux" ]; then
    if [ -f /etc/systemd/system/aione-agent.service ]; then
        echo ">>> Existing install detected — stopping and replacing it"
        systemctl stop aione-agent 2>/dev/null || true
        systemctl disable aione-agent >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/aione-agent.service
        systemctl daemon-reload
    fi
else
    for plist in /Library/LaunchDaemons/*aione-agent*.plist; do
        [ -e "$plist" ] || continue
        echo ">>> Existing install detected — stopping and replacing it"
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
    done
fi

# --- install ---------------------------------------------------------------
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR"
mv "${TMPDIR}/agent" "${INSTALL_DIR}/aione-agent"
chmod 755 "${INSTALL_DIR}/aione-agent"
# DATA_DIR holds the agent's mTLS private key and the encrypted credential
# vault — owner-only (CR-8). The service runs as root (the systemd unit has
# no User= — kardianos default — and launchd daemons run as root), so 700
# root:root stays readable by the agent while shutting out local users.
chmod 700 "$DATA_DIR"

# Write config. install_token is baked in literally because kardianos/service
# doesn't propagate install-time env vars into the systemd unit's Environment=
# directives, so a first-boot agent started by systemd would see an empty
# $AIONE_INSTALL_TOKEN and refuse to register. Tokens are single-use anyway —
# post-registration they're dead weight, not a credential.
cat > "${CONFIG_DIR}/agent.yaml" <<EOF
agent:
  name: "${NAME}"
  install_token: "${TOKEN}"
  data_dir: "${DATA_DIR}"
  heartbeat: 5s

vault:
  backend: sqlite

api:
  base_url: ${BACKEND}
  timeout: 30s
  retry_max: 5
  retry_delay: 5s

transport:
  insecure_skip_verify: false

# N1-A: written unconditionally, enabled or not. The block being ABSENT
# was the original fault — config.defaults() left SyslogConfig at its zero
# value, so there was no supported way to turn the receiver on short of
# hand-editing this file, and setting enabled: true without udp_addr bound
# nothing while still reporting the collector healthy. udp_addr is spelled
# out here so the deployed config is self-documenting rather than relying
# on the compiled-in default.
#
# The agent runs as root under systemd (this unit sets no User=), so
# binding the privileged port 514 succeeds. Containerised deployments must
# additionally publish it: docker run -p 514:514/udp ...
telemetry:
  syslog:
    enabled: ${SYSLOG_ENABLED}
    udp_addr: "0.0.0.0:514"

# U-1 (2026-07-31): written unconditionally, exactly like the syslog block
# above and for the identical reason. UpdaterConfig.Enabled is NOT set in
# config.defaults() — only Channel, Interval and RequireSigned are — so it
# takes Go's zero value, false. The block being ABSENT meant every agent
# ever installed was un-updatable: the 6-hour poll never ran, and the
# console Update button logged
#   "self_update requested but updater disabled in config; ignoring"
# and spun forever. That is why alpha.13 had to be hand-installed and never
# reached the release catalog.
#
# Only `enabled` is specified: config.Load() does `cfg := defaults()` then
# unmarshals the YAML over it, so channel/interval/require_signed keep their
# defaults (stable / 6h / true). channel MUST match the channel the release
# was published under or the agent never sees it.
updater:
  enabled: true

log:
  level: info
  pretty: false
EOF
# agent.yaml carries the install token until first registration clears it —
# owner-only (CR-8). Same service-user reasoning as DATA_DIR above: the
# agent runs as root, so 600 root:root is sufficient.
chmod 600 "${CONFIG_DIR}/agent.yaml"

# --- credential-vault KEK (headless Linux) ---------------------------------
# The sqlite vault above wraps its data-encryption key with an OS-platform
# KEK. A headless Linux server has no Secret Service, so the agent's headless
# KEK derives the wrapping key from AIONE_VAULT_MASTER_PASSWORD (PBKDF2).
# Without it the agent can't open the vault (NewPlatformKEK -> ErrKEKUnavailable).
# Generate a strong per-install master key ONCE and feed it to the service via
# a systemd drop-in EnvironmentFile (added after the unit is created below).
#
# It lives in DATA_DIR (root 700) — NOT CONFIG_DIR — so it shares the exact
# lifecycle of the wrapped DEK it protects (DATA_DIR/vault.key.enc): uninstall
# WITHOUT --purge preserves both, so a re-install resumes the SAME vault;
# --purge deletes both together. Putting it in CONFIG_DIR (which uninstall
# always removes) while the DEK in DATA_DIR survives would, on the next
# install, mint a new password that can't unwrap the old DEK — locking the
# operator out of their credentials. Generated once, preserved on re-install.
# macOS is intentionally skipped: its KEK is the Keychain (task #95 stub), not
# the master-password path, so a password here would do nothing.
if [ "$OS" = "linux" ]; then
    VAULT_ENV="${DATA_DIR}/vault.env"
    if [ ! -f "$VAULT_ENV" ]; then
        ( umask 077
          printf 'AIONE_VAULT_MASTER_PASSWORD=%s\n' \
            "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" > "$VAULT_ENV" )
        echo "    ✓ generated credential-vault master key (${VAULT_ENV})"
    else
        echo "    ✓ preserving existing credential-vault master key (${VAULT_ENV})"
    fi
    chmod 600 "$VAULT_ENV"
    chown root:root "$VAULT_ENV" 2>/dev/null || true
fi

# --- register as a system service ------------------------------------------
echo ">>> Installing system service"
AIONE_INSTALL_TOKEN="$TOKEN" \
    "${INSTALL_DIR}/aione-agent" \
    -service install \
    -config "${CONFIG_DIR}/agent.yaml"

# Wire the vault master key into the systemd unit via a drop-in so it's in the
# service's environment on every boot. kardianos/service owns the base unit
# ('-service install' above); a drop-in augments it without editing the
# generated file and re-applies cleanly when the base unit is replaced on a
# re-install. Linux/systemd only.
if [ "$OS" = "linux" ]; then
    DROPIN_DIR="/etc/systemd/system/aione-agent.service.d"
    mkdir -p "$DROPIN_DIR"
    cat > "${DROPIN_DIR}/vault.conf" <<EOF
[Service]
EnvironmentFile=${DATA_DIR}/vault.env
EOF
    chmod 644 "${DROPIN_DIR}/vault.conf"

    # Restart policy (U-1, 2026-07-31). Two separate faults, both fatal to
    # self-update, both fixed here:
    #
    #  1. Restart=always — the updater swaps the binary and exits ZERO on
    #     purpose so the service manager starts the new one. Agents through
    #     alpha.14 set Restart=on-failure (internal/service.newOSService),
    #     under which systemd reads that clean exit as an intentional stop
    #     and leaves the agent DEAD after a fully successful update. Fixed
    #     in the agent for alpha.15+, but pinned here as well so a re-install
    #     repairs hosts running an older binary — which is every host that
    #     cannot self-update, i.e. exactly the ones that need it.
    #
    #  2. RestartSec=10 — kardianos/service HARDCODES RestartSec=120 in its
    #     systemd template, so even with Restart=always every update leaves
    #     the agent dark for two minutes. It is not settable through the
    #     service.Config Option map; a drop-in is the only lever.
    #
    # Kept separate from vault.conf so the two concerns stay independently
    # greppable and either can be removed without disturbing the other.
    cat > "${DROPIN_DIR}/restart.conf" <<EOF
[Service]
Restart=always
RestartSec=10
EOF
    chmod 644 "${DROPIN_DIR}/restart.conf"
    systemctl daemon-reload
fi

if [ "$NO_START" = false ]; then
    if [ "$OS" = "linux" ]; then
        systemctl daemon-reload
        systemctl enable aione-agent >/dev/null
        systemctl start aione-agent
        sleep 2
        if systemctl is-active --quiet aione-agent; then
            echo "    ✓ service started"
        else
            echo "WARN: service did not reach active state; check journalctl -u aione-agent" >&2
        fi
    else
        # '-service install' above wrote /Library/LaunchDaemons/
        # aione-agent.plist (kardianos); '-service start' launchctl-loads
        # it. Before CR-8 this branch only printed a hint, so macOS
        # installs never actually started heartbeating despite the
        # closing message promising it.
        "${INSTALL_DIR}/aione-agent" -service start -config "${CONFIG_DIR}/agent.yaml"
        sleep 2
        if launchctl list 2>/dev/null | grep -q aione-agent; then
            echo "    ✓ service started"
        else
            echo "WARN: service did not start; check: sudo launchctl list | grep aione-agent" >&2
        fi
    fi
fi

cat <<EOF

✓ aione-agent ${VERSION} installed
  binary:  ${INSTALL_DIR}/aione-agent
  config:  ${CONFIG_DIR}/agent.yaml
  data:    ${DATA_DIR}

EOF

if [ "$NO_START" = false ]; then
    echo "Check the Roja chat UI — the new host should appear within 30 s."
elif [ "$OS" = "linux" ]; then
    echo "Service installed but NOT started. Start with: sudo systemctl start aione-agent"
else
    echo "Service installed but NOT started. Start with: sudo ${INSTALL_DIR}/aione-agent -service start -config ${CONFIG_DIR}/agent.yaml"
fi
