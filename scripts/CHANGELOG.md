# Changelog — Hermes GSM Scripts

Notable changes to the files in `C:\workspace\hermes\scripts`
(launchers, `gsm-secrets.conf`, and their docs).

## 2026-10-25

### Added

- **`hermes-gateway-reload.sh`** — manual gateway reload helper: reports
  whether `gsm-secrets.conf` / `config.yaml` are newer than the running
  gateway (`status` mode; exit `0` = stale, `1` = fresh, `2` = cannot tell)
  and restarts the daemon so the `gsm` plugin re-reads them. Distinguishes
  "gateway not running" from "gateway status query failed" (e.g. `python.exe`
  blocked by an application control policy) instead of misreporting the
  latter as "not running".
- `README.md`: both reload strategies documented under **Reloading the
  gateway** — Option 1, the manual script (recommended), and Option 2, an
  optional stale-config auto-restart snippet for the main launcher, with
  their trade-offs.
- **`hermes-gsm-git-bash-win-deepseek.sh`: stale-config auto-reload (Option 2,
  active).** Before every launch it runs `hermes-gateway-reload.sh status`
  (stdout silenced, failures visible on stderr) and restarts the gateway only
  when `config.yaml` / `gsm-secrets.conf` are newer than the daemon.
  Verified both paths: fresh → no reload, `-z` OK; touched conf → STALE
  detected, gateway restarted (5948 → 7748), `-z` OK. README's Option 2
  updated from "optional snippet" to "active by default".

### Changed

- **WhatsApp disabled** (`WHATSAPP_ENABLED=false` in `HERMES_HOME/.env`) —
  this install doesn't use it. Ends both symptoms it caused: the bridge
  death/retry loop (the June session had been invalidated server-side —
  `❌ Logged out` on every spawn; backup kept at
  `whatsapp/session.loggedout-20261025`) and the gateway startup conflict
  below. Gateway now starts with `No messaging platforms enabled`.
  If WhatsApp is ever re-enabled, reconcile the session paths first: the
  adapter checks `platforms\whatsapp\session\creds.json` while
  `hermes whatsapp` / the bridge write `whatsapp\session\creds.json`.

### Fixed

- **Chat stuck at `Gateway draining: not_ready`.** Two consecutive gateway
  starts aborted with `gateway_state: startup_failed` and
  `exit_reason: whatsapp: WhatsApp enabled but not paired` — hermes 0.22.1
  treats an enabled-but-unpaired platform as a *non-retryable startup
  conflict* and exits, leaving the CLI waiting on a gateway that will never
  become ready. Fix: disable WhatsApp (see Changed) + `hermes gateway start`
  (stale `gateway.lock` from the dead PID was reclaimed automatically).
  Verified: `gateway_state: running`, `hermes -z` → `Hola.`, exit 0.
- **`config.yaml` → `providers.mimo.key_env` corrected `MIMO_API_KEY2` →
  `MIMO_API_KEY`.** The trailing `2` pointed at a GSM secret that doesn't exist
  (only `MIMO_API_KEY` does), so selecting the `mimo` provider would have
  failed credential resolution — deepseek is the default, so nothing was
  actively broken. Set via `hermes config set providers.mimo.key_env
  MIMO_API_KEY` (CLI, not hand-editing); the launcher's new auto-reload picked
  up the config mtime and restarted the gateway to propagate it (7748 → 13468).
  User confirmed this install no longer uses mimo; the `#MIMO_API_KEY` line in
  `gsm-secrets.conf` stays commented out.
- **Smart App Control blocked the venv's unsigned `python.exe` shim (env
  incident).** SAC switched from evaluation to enforced at 14:28; the
  uv-created `venv\Scripts\python.exe` (45 KB, `NotSigned`) was denied, so
  *every* new Hermes process failed with "An Application Control policy has
  blocked this file" while the already-running gateway kept serving. Fix:
  swapped `python.exe` (and `pythonw.exe`) for uv's base interpreter
  binaries plus their DLLs (`python311.dll`, `python3.dll`, CRT) — backups
  kept as `*.bak-20261025-sac`; the original shim was renamed to
  `python.exe.blocked-shim` (still held by a pre-swap process; deletable
  after a reboot). Verified: venv activates (`sys.prefix`), `hermes -z`
  round-trip (`hola`, exit 0), reload script `status` and `restart` modes.
  Documented in README → Troubleshooting (symptoms, CI 3033/3077 evidence,
  verified swap, alternatives: signed python.org venv or SAC off).
- **Stale gateway daemon kept the failed GSM fetch from startup.** The gateway
  (PID 5596, started 13:45:58) booted while `gsm-secrets.conf` still contained
  the old `DEEPSEEK_API_KEY2` typo; the file was corrected on disk at 13:58:49,
  but the plugin reads the conf **once per process**, so the running daemon
  never saw the fix. Symptom: every chat failed with
  `No usable credentials found for provider 'deepseek'` while fresh CLI
  processes happily printed `Google Secret Manager: applied 1 secret`.
  Fix: `hermes gateway restart` (5596 → PID 4392). Verified with a clean
  `hermes -z "responde solo: hola"` (exit 0) and no new
  `Model resolution failed` entries in `logs/errors.log`.

### Documentation

- `README.md`: new troubleshooting entry — when the conf/config is fixed on
  disk but chats still fail, restart (or hot-reload) the gateway.

## 2026-10-24

### Fixed

- **`gsm-secrets.conf`: secret id typo `DEEPSEEK_API_KEY2` → `DEEPSEEK_API_KEY`.**
  The trailing `2` made the `gsm` plugin ask gcloud for a secret that does not
  exist in project `84475385566`:

  ```
  ERROR: (gcloud.secrets.versions.access) NOT_FOUND: Secret
  [projects/84475385566/secrets/DEEPSEEK_API_KEY2] not found or has no versions.
  No usable credentials found for provider 'deepseek'. Set DEEPSEEK_API_KEY.
  ```

  Because each conf line is both the GSM secret id and the env var name, the
  failed fetch also left `DEEPSEEK_API_KEY` unset — hence the follow-on
  "no usable credentials" error even though the real secret exists and is
  readable. Verified with `gcloud secrets versions access latest
  --secret=DEEPSEEK_API_KEY` (35 chars) and a clean `hermes config check`.

- **`%LOCALAPPDATA%\hermes\config.yaml`: stale `messaging` toolset entries.**
  Removed `- messaging` from `platform_toolsets.cli` and
  `platform_toolsets.whatsapp` (a bare `messaging` is not a valid toolset id;
  the valid names are `hermes-cli`, `hermes-whatsapp`, …). This silenced the
  startup `Warning: Unknown toolsets: messaging` and the two
  `⚠ platform … references unknown toolset 'messaging'` lines from
  `hermes config check`. Harmless but noisy; the session started either way.

### Documentation

- `README.md`: replaced the raw pasted error dump at the end of the file with
  a proper **Troubleshooting** section covering both failures above (symptom,
  cause, fix, and the verification commands).

### Known note (not changed)

- `config.yaml` → `providers.mimo.key_env` is `MIMO_API_KEY2` while GSM only
  contains `MIMO_API_KEY`. Not an active error (deepseek is the default
  provider) but would break if the `mimo` provider were selected.
  **Resolved 2026-10-25:** corrected to `MIMO_API_KEY` (see that day's
  changelog).
