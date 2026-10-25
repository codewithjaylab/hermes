#!/usr/bin/env bash
# hermes-gsm-gcloud-logout.sh — Close the gcloud session after a delay
#
# Revokes the gcloud credentials (user accounts + Application Default
# Credentials) that the GSM launchers use to fetch secrets from Google
# Secret Manager, so the session does not stay open indefinitely.
#
# Usage (non-interactive, used by the launcher and scripts):
#   ./hermes-gsm-gcloud-logout.sh 2h         # revoke after 2 hours (default)
#   ./hermes-gsm-gcloud-logout.sh 90m        # revoke after 90 minutes
#   ./hermes-gsm-gcloud-logout.sh 4h         # revoke after 4 hours
#   ./hermes-gsm-gcloud-logout.sh 3600       # revoke after 3600 seconds
#   ./hermes-gsm-gcloud-logout.sh now        # revoke immediately
#   DRY_RUN=1 ./hermes-gsm-gcloud-logout.sh  # print actions, do not revoke
#
# Usage (interactive — run with no arguments from a terminal, or force with -i):
#   ./hermes-gsm-gcloud-logout.sh            # menu: now / 2m / 2h / custom / cancel
#   ./hermes-gsm-gcloud-logout.sh -i         # same menu, even without a TTY
#   ./hermes-gsm-gcloud-logout.sh -i 4h      # menu, delay pre-set to 4h
#   Each menu asks for the delay AND whether to dry-run or really revoke.
#
# The launcher hermes-gsm-ubuntu.sh spawns this in the background on every
# launch (delay overridable with GCLOUD_AUTOLOGOUT_DELAY; "off" disables),
# so it always passes an explicit delay argument and never hits the menu.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/gcloud-autologout.log"

INTERACTIVE=0
case "${1:-}" in
    -i|--interactive)
        INTERACTIVE=1
        shift || true
        DELAY_INPUT="${1:-}"
        ;;
    *)
        DELAY_INPUT="${1:-}"
        ;;
esac

# No arguments + real terminal → interactive menu.
if [[ -z "$DELAY_INPUT" && -t 0 && "$INTERACTIVE" -eq 0 ]]; then
    INTERACTIVE=1
fi

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

# ── Interactive menu: ask delay, then dry-run vs real ────────────
run_interactive() {
    local delay_choice mode_choice mode_default

    echo ""
    echo "[gcloud-logout] Interactive mode — what do you want to do?"
    echo "  1) Revoke now (immediately)"
    echo "  2) Revoke in 2 minutes"
    echo "  3) Revoke in 2 hours (default)"
    echo "  4) Custom delay (e.g. 30s, 45m, 2h, 3600)"
    echo "  5) Cancel — do nothing and exit"
    while true; do
        read -r -p "Choose [3]: " delay_choice || { echo "[gcloud-logout] No input — cancelled."; exit 0; }
        delay_choice="${delay_choice:-3}"
        case "$delay_choice" in
            1) DELAY_INPUT="now"; break ;;
            2) DELAY_INPUT="2m"; break ;;
            3) DELAY_INPUT="2h"; break ;;
            4)
                while true; do
                    read -r -p "Custom delay (e.g. 30s, 45m, 2h, 3600): " DELAY_INPUT || { echo "[gcloud-logout] No input — cancelled."; exit 0; }
                    if [[ -z "$DELAY_INPUT" ]]; then
                        echo "[gcloud-logout] Empty delay — try again (Ctrl-C to cancel)."
                        continue
                    fi
                    if [[ "$DELAY_INPUT" == "off" || "$DELAY_INPUT" == "none" ]]; then
                        echo "[gcloud-logout] Disabled — nothing scheduled."
                        exit 0
                    fi
                    if parse_duration "$DELAY_INPUT" >/dev/null; then
                        break 2
                    fi
                    echo "[gcloud-logout] Invalid delay '$DELAY_INPUT' — try again (e.g. 45m, 2h, 3600)."
                done
                ;;
            5) echo "[gcloud-logout] Cancelled — nothing scheduled."; exit 0 ;;
            *) echo "[gcloud-logout] Invalid choice '$delay_choice' — try again." ;;
        esac
    done

    echo ""
    echo "[gcloud-logout] Run mode:"
    echo "  1) Real revoke (commit) — actually close the gcloud session"
    echo "  2) Dry run (preview only) — print commands, change nothing"
    mode_default=1
    [[ "${DRY_RUN:-0}" == "1" ]] && mode_default=2
    while true; do
        read -r -p "Choose [$mode_default]: " mode_choice || { echo "[gcloud-logout] No input — cancelled."; exit 0; }
        mode_choice="${mode_choice:-$mode_default}"
        case "$mode_choice" in
            1) DRY_RUN=0; break ;;
            2) DRY_RUN=1; break ;;
            *) echo "[gcloud-logout] Invalid choice '$mode_choice' — try again." ;;
        esac
    done
}

if [[ "$INTERACTIVE" -eq 1 ]]; then
    run_interactive
fi

if [[ "$DELAY_INPUT" == "off" || "$DELAY_INPUT" == "none" ]]; then
    echo "[gcloud-logout] Disabled — nothing scheduled."
    exit 0
fi

if [[ "$DELAY_INPUT" == "now" || "$DELAY_INPUT" == "0" ]]; then
    DELAY_SECONDS=0
elif [[ -n "$DELAY_INPUT" ]]; then
    DELAY_SECONDS="$(parse_duration "$DELAY_INPUT")" || {
        echo "[gcloud-logout] ERROR: invalid delay '$DELAY_INPUT' (use e.g. 90m, 2h, 3600, now)" >&2
        exit 2
    }
else
    DELAY_INPUT="2h"
    DELAY_SECONDS=7200
fi

# Interactive + real revoke + delay > 0 → hand off to a background job so the
# terminal is not blocked; the re-invocation runs non-interactively (it has an
# explicit delay argument and no TTY).
if [[ "$INTERACTIVE" -eq 1 && "${DRY_RUN:-0}" -ne 1 && "$DELAY_SECONDS" -gt 0 ]]; then
    nohup "$SCRIPT_DIR/$(basename "$0")" "$DELAY_INPUT" >>"$LOG_FILE" 2>&1 &
    echo "[gcloud-logout] gcloud session will be closed in ${DELAY_INPUT} (${DELAY_SECONDS}s)."
    echo "[gcloud-logout] Scheduled in background (pid $!), log: $LOG_FILE"
    exit 0
fi

if [[ "$INTERACTIVE" -eq 1 && "${DRY_RUN:-0}" == "1" ]]; then
    echo "[gcloud-logout] Dry run — previewing what would happen after ${DELAY_INPUT} (no wait)."
else
    echo "[gcloud-logout] $(date -u '+%Y-%m-%d %H:%M:%SZ') — gcloud session will be closed in ${DELAY_INPUT} (${DELAY_SECONDS}s)."
    [[ "$DELAY_SECONDS" -gt 0 ]] && sleep "$DELAY_SECONDS"
fi

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
