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

echo "[hermes-gsm] Launching Hermes..."
echo ""

# ── Launch Hermes ──────────────────────────────────────────────
exec "$HERMES_EXE" "$@"
