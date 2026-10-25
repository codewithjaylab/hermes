#!/usr/bin/env bash
# hermes-gateway-reload.sh — reload the Hermes gateway after config changes.
#
# Why this exists: Hermes reads config.yaml and gsm-secrets.conf ONCE per
# process. The `gsm` secret-source plugin fetches the API keys at gateway
# startup and never re-reads them, so fixing the conf on disk does nothing
# for an already-running daemon — chats keep failing with
# "No usable credentials found for provider '...'" until it restarts
# (see README.md → Troubleshooting).
#
# Usage:
#   ./hermes-gateway-reload.sh           # show report, then restart the gateway
#   ./hermes-gateway-reload.sh status    # report only, no restart
#
# `status` exit codes (for scripting; 0 = "restart advised"):
#   0  config is newer than the running gateway (stale — reload needed)
#   1  gateway is up to date, or not running (nothing to reload)
#   2  cannot determine (missing python/powershell or unparseable output)

set -euo pipefail

PYTHON_EXE="/c/Users/e4dev/AppData/Local/hermes/hermes-agent/venv/Scripts/python.exe"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# config.yaml lives in HERMES_HOME (%LOCALAPPDATA%\hermes); the conf sits
# next to this script. Backslashes normalized for Git Bash's GNU tools.
HERMES_HOME_DIR="${LOCALAPPDATA:-$HOME/AppData/Local}"
HERMES_HOME_DIR="${HERMES_HOME_DIR//\\//}"
CONFIG_YAML="$HERMES_HOME_DIR/hermes/config.yaml"
SECRETS_CONF="$SCRIPT_DIR/gsm-secrets.conf"

MODE="${1:-restart}"
case "$MODE" in
    restart|status) ;;
    -h|--help|help)
        sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "[hermes-reload] ERROR: unknown mode '$MODE' (use: restart | status)"
        exit 2
        ;;
esac

if [[ ! -f "$PYTHON_EXE" ]]; then
    echo "[hermes-reload] ERROR: Python binary not found: $PYTHON_EXE"
    exit 2
fi

# ── Helpers ─────────────────────────────────────────────────────
mtime_of() { stat -c %Y "$1" 2>/dev/null || echo 0; }
fmt_ts()   { date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "epoch $1"; }

# ── Report config mtimes first (useful even if the query fails) ─
cfg_mt="$(mtime_of "$CONFIG_YAML")"
conf_mt="$(mtime_of "$SECRETS_CONF")"
newest_mt=$cfg_mt
(( conf_mt > newest_mt )) && newest_mt=$conf_mt

echo "[hermes-reload] gsm-secrets.conf : $SECRETS_CONF"
echo "[hermes-reload]   mtime          : $(fmt_ts "$conf_mt")"
echo "[hermes-reload] config.yaml      : $CONFIG_YAML"
echo "[hermes-reload]   mtime          : $(fmt_ts "$cfg_mt")"

# ── Query gateway status. Exit 2 if the query itself fails (e.g.      ─
# ── python.exe blocked by WDAC / Smart App Control) — NOT "not running" ─
get_gw_pid() {
    local out
    out="$("$PYTHON_EXE" -m hermes_cli.main gateway status 2>&1 || true)"
    if grep -qiE 'Gateway is running' <<<"$out"; then
        grep -oE 'PID:[[:space:]]*[0-9]+' <<<"$out" | grep -oE '[0-9]+' | head -n1 || true
    elif grep -qiE 'not running' <<<"$out"; then
        printf ''
    else
        echo "[hermes-reload] ERROR: could not query gateway status (is $PYTHON_EXE blocked?):" >&2
        echo "$out" >&2
        return 2
    fi
}

gw_pid="$(get_gw_pid)"

# ── Gateway start time (Windows process creation) ───────────────
gw_start=""
if [[ -n "$gw_pid" ]]; then
    if command -v powershell.exe >/dev/null 2>&1; then
        PS_EXE="powershell.exe"
    elif [[ -x "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]]; then
        PS_EXE="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    else
        PS_EXE=""
    fi
    if [[ -n "$PS_EXE" ]]; then
        ps_cmd="[int64][math]::Floor(((Get-Process -Id ${gw_pid}).StartTime.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds)"
        gw_start="$("$PS_EXE" -NoProfile -Command "$ps_cmd" 2>/dev/null | tr -d '[:space:]' || true)"
        [[ "$gw_start" =~ ^[0-9]+$ ]] || gw_start=""
    fi
fi

# ── Verdict: 0 = stale, 1 = fresh/not running, 2 = unknown ──────
code=1
if [[ -z "$gw_pid" ]]; then
    echo "[hermes-reload] gateway          : not running (it will read the current config when it starts)"
    code=1
elif [[ -z "$gw_start" || "$newest_mt" == "0" ]]; then
    echo "[hermes-reload] gateway          : running (PID $gw_pid), start time unknown"
    echo "[hermes-reload] verdict          : UNKNOWN — cannot compare config mtime vs gateway start"
    code=2
elif (( newest_mt > gw_start )); then
    echo "[hermes-reload] gateway          : running (PID $gw_pid), started $(fmt_ts "$gw_start")"
    echo "[hermes-reload] verdict          : STALE — config changed after the gateway started; reload advised"
    code=0
else
    echo "[hermes-reload] gateway          : running (PID $gw_pid), started $(fmt_ts "$gw_start")"
    echo "[hermes-reload] verdict          : fresh — gateway is newer than the config"
    code=1
fi

if [[ "$MODE" == "status" ]]; then
    exit "$code"
fi

# ── Restart ─────────────────────────────────────────────────────
echo "[hermes-reload] restarting gateway..."
set +e
restart_out="$("$PYTHON_EXE" -m hermes_cli.main gateway restart 2>&1)"
rc=$?
set -e
echo "$restart_out"
if [[ $rc -ne 0 ]]; then
    echo "[hermes-reload] ERROR: gateway restart failed (exit $rc)"
    exit "$rc"
fi

new_pid="$(get_gw_pid)"
if [[ -n "$new_pid" ]]; then
    echo "[hermes-reload] OK: gateway running (PID $new_pid) — config and GSM secrets re-read."
else
    echo "[hermes-reload] WARNING: restart reported success but the gateway is not running."
    exit 1
fi
