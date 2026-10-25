#!/usr/bin/env bash
# hermes-gsm.sh — Canonical bash forwarder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/hermes-gsm-git-bash-win.sh" "$@"
