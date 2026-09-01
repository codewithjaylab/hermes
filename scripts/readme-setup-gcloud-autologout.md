# readme-setup-gcloud-autologout.md

Objective: automatically close the gcloud session ~2 hours after launching
Hermes via the GSM wrapper, so the Google credentials used to fetch API keys
from Secret Manager don't stay active indefinitely.

## What changed

1. **New file `scripts/hermes-gsm-gcloud-logout.sh`** — standalone Bash helper
   that waits a configurable delay, then revokes the gcloud session:
   - `gcloud auth revoke --all --quiet` (user accounts)
   - `gcloud auth application-default revoke --quiet` (ADC, used by
     `gcloud auth application-default login`)
2. **`scripts/hermes-gsm-ubuntu.sh`** — before `exec`-ing Hermes, it now spawns
   the helper in the background with `nohup`, appending output to
   `scripts/gcloud-autologout.log` (covered by the repo's `*.log` gitignore).

## Exact commands used (during setup)

```bash
chmod +x scripts/hermes-gsm-gcloud-logout.sh
```

## Usage

```bash
hermes                     # default: gcloud session closed 2h after launch
GCLOUD_AUTOLOGOUT_DELAY=90m hermes   # custom delay
GCLOUD_AUTOLOGOUT_DELAY=off hermes   # disable auto-logout
./hermes-gsm-gcloud-logout.sh 4h     # standalone: revoke in 4h
./hermes-gsm-gcloud-logout.sh now    # standalone: revoke immediately
DRY_RUN=1 ./hermes-gsm-gcloud-logout.sh now   # preview, no revoke
```

Accepted delay formats: `30s`, `45m`, `2h`, `1d`, plain seconds (`3600`),
`now` (immediate), `off`/`none` (no-op).

## Verification (expected output)

```bash
$ DRY_RUN=1 ./hermes-gsm-gcloud-logout.sh now
[gcloud-logout] 2026-09-01 09:16:16Z — gcloud session will be closed in now (0s).
[gcloud-logout] 2026-09-01 09:16:16Z — closing gcloud session...
[gcloud-logout] [DRY RUN] would run: gcloud auth revoke --all --quiet
[gcloud-logout] [DRY RUN] would run: gcloud auth application-default revoke --quiet
[gcloud-logout] Done (revoked=0 dry_run=1).
```

On a real launch, `hermes-gsm-ubuntu.sh` prints:

```
[hermes-gsm] gcloud session auto-close scheduled in 2h (pid 12345)
```

After the delay elapses, `scripts/gcloud-autologout.log` shows the revoke
outcome, and `gcloud auth list` reports no active accounts.

## Behavior notes

- The scheduled job runs independently of the Hermes process (nohup + `&`), so
  closing the chat does NOT cancel the pending logout.
- Revoking only affects future gcloud calls: the secrets were already exported
  into the running Hermes process's environment, so an in-progress chat keeps
  working after the logout fires.
- The next `hermes` launch after a logout will need gcloud re-authentication
  (`gcloud auth application-default login`) before secrets can be fetched
  again; until then the wrapper warns and skips the secrets.

## Revert

```bash
# Remove the scheduling block from hermes-gsm-ubuntu.sh, or just:
GCLOUD_AUTOLOGOUT_DELAY=off hermes   # no code change needed
# To delete the helper and log:
rm scripts/hermes-gsm-gcloud-logout.sh scripts/gcloud-autologout.log
```

## Prerequisites

- Same as the launchers: gcloud SDK on PATH, authenticated account with
  Secret Manager Secret Accessor role.
- GNU `sleep` not required — the helper parses durations itself, so it also
  works on macOS/BSD (delay given as plain seconds or `30s`/`45m`/`2h`/`1d`).
