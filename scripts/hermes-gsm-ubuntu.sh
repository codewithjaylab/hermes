#!/usr/bin/env bash
# hermes-gsm-ubuntu.sh — Launch Hermes with API keys from Google Secret Manager
# For Ubuntu / Debian / general Linux (bash).
#
# Usage:
#   ./hermes-gsm-ubuntu.sh                       # interactive chat
#   ./hermes-gsm-ubuntu.sh -q "pregunta"         # single query
#   ./hermes-gsm-ubuntu.sh --resume sesion       # resume session
#
# Or add to ~/.bashrc:
#   alias hermes='~/workspace/hermes/scripts/hermes-gsm-ubuntu.sh'
#
# Prerequisites:
#   - gcloud SDK installed and on PATH (apt: https://cloud.google.com/sdk/docs/install)
#   - Secrets created in GSM (DEEPSEEK_API_KEY, etc.)
#   - gcloud auth application-default login (for ADC)

set -euo pipefail

# ── Locate the hermes executable ───────────────────────────────
# Prefer whatever is on PATH, then common install locations.
HERMES_EXE="$(command -v hermes || true)"
if [[ -z "$HERMES_EXE" ]]; then
    for candidate in \
        "$HOME/.local/bin/hermes" \
        "$HOME/.hermes/bin/hermes" \
        "/usr/local/bin/hermes" \
        "/opt/hermes-agent/venv/bin/hermes" \
        "$HOME/workspace/Hermes-Agent/venv/bin/hermes"
    do
        if [[ -x "$candidate" ]]; then
            HERMES_EXE="$candidate"
            break
        fi
    done
fi

if [[ -z "$HERMES_EXE" || ! -x "$HERMES_EXE" ]]; then
    echo "[hermes-gsm] ERROR: hermes executable not found. Install Hermes or set HERMES_EXE." >&2
    exit 1
fi

# ── Config ─────────────────────────────────────────────────────
# Secrets are read from gsm-secrets.conf (one per line, # for comments)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/gsm-secrets.conf"

SECRETS=()
if [[ -f "$CONFIG_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and blank/whitespace-only lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        SECRETS+=("$line")
    done < "$CONFIG_FILE"
else
    echo "[hermes-gsm] ERROR: Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# ── Fetch secrets from GSM ─────────────────────────────────────
echo "[hermes-gsm] Fetching secrets from Google Secret Manager..."

for secret_name in "${SECRETS[@]}"; do
    value=$(gcloud secrets versions access latest \
        --secret="$secret_name" 2>/dev/null) || {
        echo "[hermes-gsm] WARNING: Could not fetch secret '$secret_name' — skipping"
        continue
    }
    export "$secret_name"="$value"
    echo "[hermes-gsm]   OK $secret_name loaded"
done

# ── Schedule gcloud auto-logout ────────────────────────────────
# Close the gcloud session shortly after launch so the credentials used
# to fetch the secrets don't stay active. Override the delay with the
# env var GCLOUD_AUTOLOGOUT_DELAY (e.g. "90m", "4h"); "off" disables.
GCLOUD_AUTOLOGOUT_DELAY="${GCLOUD_AUTOLOGOUT_DELAY:-2h}"
if [[ -n "$GCLOUD_AUTOLOGOUT_DELAY" && "$GCLOUD_AUTOLOGOUT_DELAY" != "off" ]]; then
    nohup "$SCRIPT_DIR/hermes-gsm-gcloud-logout.sh" "$GCLOUD_AUTOLOGOUT_DELAY" \
        >>"$SCRIPT_DIR/gcloud-autologout.log" 2>&1 &
    echo "[hermes-gsm] gcloud session auto-close scheduled in $GCLOUD_AUTOLOGOUT_DELAY (pid $!)"
fi

# ── Virtual display for GUI tools (computer_use) ───────────────
# cua-driver (hermes computer-use) requires a reachable X11 display. On
# headless hosts we start a virtual one on :99 (idempotent) unless the
# caller already provided DISPLAY.
#   HERMES_XVFB_DISPLAY=":98"  -> use another display number
#   HERMES_XVFB_DISPLAY=off    -> never start Xvfb
if [[ -z "${DISPLAY:-}" ]]; then
    HERMES_XVFB_DISPLAY="${HERMES_XVFB_DISPLAY:-:99}"
    if [[ "$HERMES_XVFB_DISPLAY" != "off" ]] && command -v Xvfb >/dev/null 2>&1; then
        if ! pgrep -f "Xvfb $HERMES_XVFB_DISPLAY " >/dev/null 2>&1; then
            nohup Xvfb "$HERMES_XVFB_DISPLAY" -screen 0 1920x1080x24 -nolisten tcp \
                >>"${TMPDIR:-/tmp}/hermes-xvfb.log" 2>&1 &
            sleep 0.5
        fi
        export DISPLAY="$HERMES_XVFB_DISPLAY"
        echo "[hermes-gsm] Xvfb display $DISPLAY ready"

        # cua-driver inspects UI through AT-SPI on a D-Bus session bus.
        # A headless host has neither, so create both here.
        if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" \
              && "$(stat -c %u "$XDG_RUNTIME_DIR" 2>/dev/null || echo "")" != "$(id -u)" ]]; then
            unset XDG_RUNTIME_DIR
        fi
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$HOME/.hermes/run}"
        mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

        # A stale/foreign bus address (e.g. /run/user/0/bus inherited from
        # a root shell) makes both dbus-send and at-spi fail, so probe it
        # and fall back to our own session bus.
        if ! command -v dbus-send >/dev/null 2>&1 \
           || ! dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
                  / org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
            unset DBUS_SESSION_BUS_ADDRESS
            if command -v dbus-launch >/dev/null 2>&1; then
                eval "$(dbus-launch --sh-syntax)" 2>/dev/null || true
            fi
        fi
        if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v dbus-send >/dev/null 2>&1; then
            if ! dbus-send --session --dest=org.a11y.Bus --type=method_call \
                    /org/a11y/bus org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
                if [[ -x /usr/libexec/at-spi-bus-launcher ]]; then
                    /usr/libexec/at-spi-bus-launcher --launch-immediately >/dev/null 2>&1 &
                    sleep 1
                fi
            fi
            if dbus-send --session --dest=org.a11y.Bus --type=method_call \
                    /org/a11y/bus org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
                echo "[hermes-gsm] D-Bus/AT-SPI session ready"
            else
                echo "[hermes-gsm] WARNING: AT-SPI bus unavailable — computer_use UI inspection will be degraded" >&2
            fi
        else
            echo "[hermes-gsm] WARNING: no D-Bus session — computer_use UI inspection will be degraded" >&2
        fi
    else
        echo "[hermes-gsm] WARNING: no DISPLAY and Xvfb unavailable — computer_use will stay degraded" >&2
    fi
fi

echo "[hermes-gsm] Launching Hermes..."
echo ""

# ── Launch Hermes ──────────────────────────────────────────────
exec "$HERMES_EXE" "$@"
