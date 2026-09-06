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
#   - gcloud SDK installed, authenticated and with an active project
#   - Secrets created in GSM (DEEPSEEK_API_KEY, etc.)
#   - gcloud auth login (gcloud secrets uses user creds, NOT ADC)

set -euo pipefail

HERMES_EXE="C:/Users/e4dev/AppData/Local/hermes/hermes-agent/venv/Scripts/hermes.exe"

# ── Config ─────────────────────────────────────────────────────
# Secrets are read from gsm-secrets.conf (one per line, # for comments)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/gsm-secrets.conf"

# Trim leading/trailing whitespace, including CR from CRLF files
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

SECRETS=()
if [[ -f "$CONFIG_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Normalize: strip CR (Windows CRLF) and surrounding whitespace
        line="$(trim "$line")"
        # Skip comments and blank lines
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Only accept valid environment-variable names
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            SECRETS+=("$line")
        else
            echo "[hermes-gsm] WARNING: skipping invalid secret name: '$line'"
        fi
    done < "$CONFIG_FILE"
else
    echo "[hermes-gsm] ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

if [[ ${#SECRETS[@]} -eq 0 ]]; then
    echo "[hermes-gsm] ERROR: No secrets to load (empty config?)"
    exit 1
fi

if [[ ! -f "$HERMES_EXE" ]]; then
    echo "[hermes-gsm] ERROR: Hermes binary not found: $HERMES_EXE"
    exit 1
fi

# ── Fetch secrets from GSM ─────────────────────────────────────
echo "[hermes-gsm] Fetching secrets from Google Secret Manager..."

for secret_name in "${SECRETS[@]}"; do
    value="$(gcloud secrets versions access latest \
        --secret="$secret_name" 2>/dev/null)" || {
        echo "[hermes-gsm] WARNING: could not fetch secret '$secret_name' — skipping"
        continue
    }
    value="${value%$'\r'}"   # strip CR if the value carries one
    if [[ -z "$value" ]]; then
        echo "[hermes-gsm] WARNING: secret '$secret_name' is empty — skipping"
        continue
    fi
    export "$secret_name=$value"
    echo "[hermes-gsm]   OK $secret_name loaded"
done

echo "[hermes-gsm] Launching Hermes..."
echo ""

# ── Launch Hermes ──────────────────────────────────────────────
exec "$HERMES_EXE" "$@"
