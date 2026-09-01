#!/usr/bin/env bash
# hermes-gsm.sh — Launch Hermes with API keys from Google Secret Manager
# For Git Bash / MSYS2 on Windows.
#
# Usage:
#   ./hermes-gsm.sh                       # interactive chat
#   ./hermes-gsm.sh -q "pregunta"         # single query
#   ./hermes-gsm.sh --resume sesion       # resume session
#
# Or add to ~/.bashrc:
#   alias hermes='~/workspace/hermes/scripts/hermes-gsm.sh'
#
# Prerequisites:
#   - gcloud SDK installed and on PATH
#   - Secrets created in GSM (DEEPSEEK_API_KEY, etc.)
#   - gcloud auth application-default login (for ADC)

set -euo pipefail

HERMES_EXE="C:/Users/e4dev/AppData/Local/hermes/hermes-agent/venv/Scripts/hermes.exe"

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
    echo "[hermes-gsm] ERROR: Config file not found: $CONFIG_FILE"
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

echo "[hermes-gsm] Launching Hermes..."
echo ""

# ── Launch Hermes ──────────────────────────────────────────────
exec "$HERMES_EXE" "$@"
