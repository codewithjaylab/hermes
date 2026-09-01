#!/usr/bin/env bash
# hermes-gsm-gcloud-logout.sh — Close the gcloud session after a delay
#
# Revokes the gcloud credentials (user accounts + Application Default
# Credentials) that the GSM launchers use to fetch secrets from Google
# Secret Manager, so the session does not stay open indefinitely.
#
# Usage:
#   ./hermes-gsm-gcloud-logout.sh            # revoke after 2 hours (default)
#   ./hermes-gsm-gcloud-logout.sh 90m        # revoke after 90 minutes
#   ./hermes-gsm-gcloud-logout.sh 4h         # revoke after 4 hours
#   ./hermes-gsm-gcloud-logout.sh 3600       # revoke after 3600 seconds
#   ./hermes-gsm-gcloud-logout.sh now        # revoke immediately
#   DRY_RUN=1 ./hermes-gsm-gcloud-logout.sh  # print actions, do not revoke
#
# The launcher hermes-gsm-ubuntu.sh spawns this in the background on every
# launch (delay overridable with GCLOUD_AUTOLOGOUT_DELAY; "off" disables).

set -euo pipefail

DELAY_INPUT="${1:-2h}"

# ── Duration parser: 30s / 5m / 2h / 1d / plain seconds ─────────
parse_duration() {
    local input="$1"
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
        return 0
    fi
    if [[ "$input" =~ ^([0-9]+)([smhd])$ ]]; then
        local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
        case "$unit" in
            s) echo "$num" ;;
            m) echo $((num * 60)) ;;
            h) echo $((num * 3600)) ;;
            d) echo $((num * 86400)) ;;
        esac
        return 0
    fi
    return 1
}

if [[ "$DELAY_INPUT" == "off" || "$DELAY_INPUT" == "none" ]]; then
    echo "[gcloud-logout] Disabled — nothing scheduled."
    exit 0
fi

if [[ "$DELAY_INPUT" == "now" || "$DELAY_INPUT" == "0" ]]; then
    DELAY_SECONDS=0
else
    DELAY_SECONDS="$(parse_duration "$DELAY_INPUT")" || {
        echo "[gcloud-logout] ERROR: invalid delay '$DELAY_INPUT' (use e.g. 90m, 2h, 3600, now)" >&2
        exit 2
    }
fi

echo "[gcloud-logout] $(date -u '+%Y-%m-%d %H:%M:%SZ') — gcloud session will be closed in ${DELAY_INPUT} (${DELAY_SECONDS}s)."
[[ "$DELAY_SECONDS" -gt 0 ]] && sleep "$DELAY_SECONDS"

echo "[gcloud-logout] $(date -u '+%Y-%m-%d %H:%M:%SZ') — closing gcloud session..."

REVOKED=0
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[gcloud-logout] [DRY RUN] would run: gcloud auth revoke --all --quiet"
    echo "[gcloud-logout] [DRY RUN] would run: gcloud auth application-default revoke --quiet"
else
    if gcloud auth revoke --all --quiet >/dev/null 2>&1; then
        echo "[gcloud-logout]   OK user accounts revoked"
        REVOKED=1
    else
        echo "[gcloud-logout]   (no user accounts to revoke)"
    fi
    if gcloud auth application-default revoke --quiet >/dev/null 2>&1; then
        echo "[gcloud-logout]   OK application-default credentials revoked"
        REVOKED=1
    else
        echo "[gcloud-logout]   (no application-default credentials to revoke)"
    fi
fi

echo "[gcloud-logout] Done (revoked=$REVOKED dry_run=${DRY_RUN:-0})."
