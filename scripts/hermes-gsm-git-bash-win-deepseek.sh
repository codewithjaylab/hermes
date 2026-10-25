#!/usr/bin/env bash
# hermes-gsm-git-bash-win-deepseek.sh — Launch Hermes on Windows (Git Bash / MSYS2).
#
# Usage:
#   ./hermes-gsm-git-bash-win-deepseek.sh                       # interactive chat
#   ./hermes-gsm-git-bash-win-deepseek.sh -z "pregunta"         # single query
#   ./hermes-gsm-git-bash-win-deepseek.sh --resume sesion       # resume session
#
# Or add to ~/.bashrc:
#   alias hermes='$HERMES/scripts/hermes-gsm-git-bash-win-deepseek.sh'
#
# API keys are NOT fetched here: the 'gsm' secret-source plugin reads
# gsm-secrets.conf and pulls them from Google Secret Manager inside every Hermes
# process (CLI, gateway, cron). This wrapper only picks the Python to run and
# routes through the Headroom proxy when one is up.
#
# Prerequisites:
#   - gcloud SDK installed and authenticated (gcloud auth login — user creds, NOT ADC)
#   - Secrets created in GSM (DEEPSEEK_API_KEY, etc.) and an active gcloud project
#   - `hermes plugins enable gsm` + secrets.gsm enabled in config.yaml (see README.md)

set -euo pipefail

PYTHON_EXE="/c/Users/e4dev/AppData/Local/hermes/hermes-agent/venv/Scripts/python.exe"

if [[ ! -f "$PYTHON_EXE" ]]; then
    echo "[hermes-gsm] ERROR: Python binary not found: $PYTHON_EXE"
    exit 1
fi

# ── Check if Headroom proxy is running on port 8787 ────────────
if netstat -ano 2>/dev/null | grep -q "8787"; then
    echo "[hermes-gsm] Headroom proxy detected on port 8787. Routing requests through proxy to save tokens."
    export DEEPSEEK_BASE_URL="http://localhost:8787/v1"
    export GEMINI_BASE_URL="http://localhost:8787/v1beta"
else
    echo "[hermes-gsm] Headroom proxy not detected on port 8787. Direct connection will be used."
fi

echo "[hermes-gsm] Launching Hermes..."
echo ""

# ── Launch Hermes ──────────────────────────────────────────────
exec "$PYTHON_EXE" -m hermes_cli.main "$@"
