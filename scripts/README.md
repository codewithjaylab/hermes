# Hermes GSM Launchers

Launchers for the **Hermes CLI**, paired with the `gsm` secret-source plugin that
pulls API keys from **Google Secret Manager (GSM)**.

The keys are fetched by Hermes itself at the start of every process and kept in
memory only — they are never written to `.env` or to any other file on disk.

> **How it works in depth** (root cause of the change, the Python plugin,
> startup timing, security model, troubleshooting): **[`GSM-PLUGIN.md`](GSM-PLUGIN.md)**

## Prerequisites

1.  **Google Cloud SDK (gcloud):** Must be installed and available in your `PATH`.
2.  **Authentication:** The `gcloud` CLI is what reads the secrets, so authenticate it with your own user credentials (not ADC):
    ```bash
    gcloud auth login
    gcloud config set project <your-project-id>
    ```
3.  **Secrets in GSM:** Ensure you have the required secrets (e.g., `DEEPSEEK_API_KEY`) created in your Google Cloud Project and that your account has the `Secret Manager Secret Accessor` role.
4.  **The `gsm` plugin enabled:** secrets are injected by Hermes itself, not by the launchers:
    ```bash
    hermes plugins enable gsm
    hermes config set secrets.gsm.enabled true
    hermes config set secrets.gsm.secrets_file C:/workspace/hermes/scripts/gsm-secrets.conf
    ```

## Headless support (`browser` and `computer_use` toolsets)

On machines without a desktop, `hermes-gsm-ubuntu.sh` brings up the virtual
display and accessibility infrastructure the GUI tools need:

- **Xvfb** on `:99` (1920x1080x24) -> `DISPLAY` for `computer_use`.
- **Own D-Bus session + AT-SPI bus** -> UI inspection for `cua-driver`.
- Skipped when `DISPLAY` is already set (real desktop).

Controls:

```bash
HERMES_XVFB_DISPLAY=":98"   # use another display number
HERMES_XVFB_DISPLAY=off     # never start Xvfb
```

Host dependencies (once, needs sudo):

```bash
sudo apt-get install -y xvfb x11-utils dbus-x11 at-spi2-core \
    libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64 libgbm1 \
    libxdamage1 libxcomposite1 libxrandr2 libxfixes3 libcups2t64 \
    libdrm2 libasound2t64 libnss3 libnspr4 libpango-1.0-0 libcairo2 \
    libxkbcommon0 libxshmfence1
```

For the `browser` toolset (Chromium managed by `agent-browser`):

```bash
npx -y agent-browser@^0.26.0 install     # installs Chrome into ~/.agent-browser
ln -sf ~/.agent-browser/browsers/chrome-*/chrome ~/.local/bin/chromium
```

Verify:

```bash
hermes computer-use doctor     # should report "ok"
```



## Included Scripts

| Platform | Script | Shell |
| :--- | :--- | :--- |
| **Windows** | `hermes-gsm-git-bash-win-deepseek.sh` | Git Bash / MSYS2 (active launcher) |
| **Windows** | `hermes-gateway-reload.sh` | Git Bash / MSYS2 — reload the gateway after config changes |
| Windows / Linux | `hermes-gsm.cmd`, `.ps1`, `.sh`, `-ubuntu.sh`, `hermes-gsm-gcloud-logout.sh` | CMD / PowerShell / Bash — legacy launchers, moved to `scripts/archived/` |

## Auto-Logout (gcloud session)

> Applies to the **legacy** launchers in `scripts/archived/`. The active launcher
> no longer runs `gcloud` itself (the `gsm` plugin does, once per Hermes process),
> so there is no session for it to schedule.

`hermes-gsm-ubuntu.sh` schedules a background job that closes the gcloud
session shortly after launch, so the credentials used to fetch secrets from
Google Secret Manager don't stay active indefinitely.

- Default delay: **2 hours** after launch.
- Override with the environment variable: `GCLOUD_AUTOLOGOUT_DELAY=90m hermes`
  (accepts `30s`, `45m`, `2h`, `1d`, or plain seconds).
- Disable with: `GCLOUD_AUTOLOGOUT_DELAY=off hermes`.
- The helper can also be run standalone: `./hermes-gsm-gcloud-logout.sh 4h`
  schedules a revoke 4 hours from now; `now` revokes immediately.
- Interactive mode: run with no arguments from a terminal (or add `-i`) for a
  menu — revoke now / in 2 minutes / in 2 hours / custom delay / cancel, then
  choose dry-run (preview) or real revoke.
- It revokes both `gcloud auth` user accounts and Application Default
  Credentials (`gcloud auth application-default revoke`).
- Output is appended to `scripts/gcloud-autologout.log` (git-ignored).
- Dry-run for testing: `DRY_RUN=1 ./hermes-gsm-gcloud-logout.sh now` prints the
  commands without revoking anything.

## Installation

1.  Clone or copy these scripts to a directory of your choice (e.g., `C:\workspace\hermes\scripts`).
2.  **Optional:** Add the directory to your system `PATH` to run `hermes-gsm` from anywhere.

### Adding Aliases

To use a shorter command (like `hermes`), add the following to your shell profile:

**PowerShell (`$PROFILE`):**
```powershell
# 'bash' on PATH may be WSL on this host — name Git Bash explicitly.
function hermes { & "C:\Program Files\Git\bin\bash.exe" "C:/workspace/hermes/scripts/hermes-gsm-git-bash-win-deepseek.sh" @args }
```

**Bash (`~/.bashrc` or `~/.zshrc`):**
```bash
alias hermes='bash /c/workspace/hermes/scripts/hermes-gsm-git-bash-win-deepseek.sh'
```

## Usage

You can pass any Hermes CLI arguments directly to the scripts.

```bash
# Start an interactive chat
hermes-gsm

# Single query mode
hermes-gsm -z "Explain quantum entanglement"

# Resume a previous session
hermes-gsm --resume my-session-id
```

## Configuration

Secret names live in a single flat-file config: **`gsm-secrets.conf`**, next to the scripts.

**Hermes reads it, not the launchers.** The `gsm` secret-source plugin pulls each name
from Google Secret Manager at the start of *every* Hermes process — CLI, the long-running
gateway, and cron alike — so the keys reach the process that actually talks to the model
(the gateway never sees a launcher's environment variables).

```
# ── API Keys from Google Secret Manager ──
DEEPSEEK_API_KEY
OPENROUTER_API_KEY
NOVITA_API_KEY
# GOOGLE_API_KEY       # commented out — won't be fetched
```

- Lines starting with `#` are comments (blank lines are ignored)
- Each name must be a legal environment-variable name: it is both the GSM secret id
  and the env var it supplies
- Changes take effect on the next Hermes start — the plugin re-reads the file once per process

Plugin keys it honours (all under `secrets.gsm` in `config.yaml`):

| Key | Default | Meaning |
| :--- | :--- | :--- |
| `enabled` | `false` | Master switch |
| `secrets_file` | `''` | Path to the flat file above |
| `secrets` | `[]` | Inline list of ids, merged with `secrets_file` |
| `project_id` | `''` | GCP project; empty = gcloud's active project |
| `binary_path` | `''` | Path to `gcloud`; empty = `PATH` |
| `cache_ttl_seconds` | `0` | `0` keeps keys off disk; raise it to skip the ~2.5s `gcloud` round-trip (values then cache `0600` under `~/.hermes/cache/` for that long) |
| `override_existing` | `true` | GSM values win over `.env`/shell values, so rotation applies |

> **Note:** the launcher runs Hermes through its venv Python:
> `C:\Users\e4dev\AppData\Local\hermes\hermes-agent\venv\Scripts\python.exe -m hermes_cli.main`
> If your installation path is different, update the `PYTHON_EXE` variable inside the script.

## Reloading the gateway (config / gsm-secrets.conf changes)

Hermes reads `config.yaml` and `gsm-secrets.conf` **once per process** (deep
dive: [GSM-PLUGIN.md](GSM-PLUGIN.md) §14.5). The `gsm` plugin fetches the API
keys when the gateway **starts** and never re-reads them, so editing those
files on disk does nothing for an already-running daemon — chats keep failing
until it reloads. Two ways to handle this:

### Option 1 — manual reload (recommended): `hermes-gateway-reload.sh`

```bash
./hermes-gateway-reload.sh          # report + restart the gateway
./hermes-gateway-reload.sh status   # report only (no restart)
```

The report compares the mtime of `gsm-secrets.conf` / `config.yaml` against
the gateway process start time:

```
[hermes-reload] gsm-secrets.conf : /c/workspace/hermes/scripts/gsm-secrets.conf
[hermes-reload]   mtime          : 2026-10-25 13:58:49
[hermes-reload] config.yaml      : C:/Users/e4dev/AppData/Local/hermes/config.yaml
[hermes-reload]   mtime          : 2026-10-25 13:59:08
[hermes-reload] gateway          : running (PID 4392), started 2026-10-25 14:15:31
[hermes-reload] verdict          : fresh — gateway is newer than the config
```

`status` exit codes (for scripting): **`0`** stale — restart advised ·
**`1`** fresh, or gateway not running (nothing to reload) ·
**`2`** cannot determine (e.g. the gateway query failed because
`python.exe` is blocked by an application control policy).

The restart briefly disconnects messaging platforms (WhatsApp/Telegram) and
cron; the gateway comes back within seconds and re-fetches the GSM secrets.

### Option 2 — automatic stale-config check in the main launcher

**Active by default** in `hermes-gsm-git-bash-win-deepseek.sh` — right before
launching Hermes it runs the `status` check and reloads the gateway only when
the config is actually newer than the daemon (delete the block to opt out):

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if "$SCRIPT_DIR/hermes-gateway-reload.sh" status >/dev/null; then
    echo "[hermes-gsm] Config changed after the gateway started — reloading it..."
    "$SCRIPT_DIR/hermes-gateway-reload.sh"
fi
```

The check's stdout is silenced (its stderr — query failures — stays visible).
Otherwise it does nothing.

Trade-offs paid while this block stays enabled:

- Every `hermes` launch pays for an extra `gateway status` round-trip —
  Python start-up plus the plugin's ~2.5 s `gcloud` fetch in that short-lived
  check process: typically a few seconds added to **every** start.
- When it does fire, platforms disconnect for the duration of the restart.
- Launchers that fire in tight loops (cron, `-z` scripts) make the cost
  visible — consider removing the block there and using Option 1 manually.

## Global VS Code Integration

To run Hermes dynamically from any VS Code project workspace with automatic environment injection from Google Secret Manager, configure a Global User Task.

On Windows, the global VS Code task configuration file is located at:
`%APPDATA%\Code\User\tasks.json`

Append the following JSON payload into your global tasks configuration:

```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "Launch Hermes with GSM",
            "type": "shell",
            "command": "C:/Program Files/Git/bin/bash.exe",
            "args": ["C:/workspace/hermes/scripts/hermes-gsm-git-bash-win-deepseek.sh"],
            "options": {
                "cwd": "${workspaceFolder}"
            },
            "problemMatcher": [],
            "group": {
                "kind": "build",
                "isDefault": true
            },
            "presentation": {
                "echo": true,
                "reveal": "always",
                "focus": true,
                "panel": "dedicated",
                "showReuseMessage": false,
                "clear": true
            }
        }
    ]
}
```

## Troubleshooting

### Fixed the conf/config on disk, but chats still fail with "No usable credentials"

**Symptom (2026-10-25):** `gsm-secrets.conf` is correct and CLI processes print
`Google Secret Manager: applied 1 secret`, yet every chat dies with
`No usable credentials found for provider 'deepseek'` and `logs/errors.log`
shows the failure prefixed `gateway.run`.

**Cause:** the **gateway daemon** reads `gsm-secrets.conf` / `config.yaml` once,
at process start. If it booted while the conf was still broken (here: the
`DEEPSEEK_API_KEY2` typo), fixing the file on disk does nothing for the live
daemon — the plugin re-fetches per process, not per chat.

**Fix:** `./hermes-gateway-reload.sh` (or plain `hermes gateway restart`; or
`hermes plugins enable gsm` for a hot plugin reload). Then verify:

```bash
hermes -z "responde solo: hola"     # should answer, exit 0
```

### `gcloud could not read … NOT_FOUND: Secret […] not found or has no versions`

**Symptom (as seen with the `DEEPSEEK_API_KEY2` typo):**

```
Google Secret Manager: gcloud could not read 1 configured secret(s): ERROR:
(gcloud.secrets.versions.access) NOT_FOUND: Secret
[projects/84475385566/secrets/DEEPSEEK_API_KEY2] not found or has no versions.
Google Secret Manager: → Check secrets.gsm.secrets and secrets.gsm.project_id
in config.yaml against the ids that exist in GSM.
No usable credentials found for provider 'deepseek'. Set DEEPSEEK_API_KEY.
```

**Cause:** every name in `gsm-secrets.conf` is used as *both* the GSM secret id
*and* the environment variable the provider reads. A name that doesn't exist in
GSM fails the fetch, so the expected env var never gets set — which is why the
missing-secret error is followed by a "no usable credentials" error even though
the real secret (`DEEPSEEK_API_KEY`) exists and is readable.

**Fix (2026-10-24):** corrected `gsm-secrets.conf` from `DEEPSEEK_API_KEY2`
back to `DEEPSEEK_API_KEY`. Verify with:

```bash
# 1. The id in gsm-secrets.conf must exist in GSM and be readable:
gcloud secrets versions access latest --secret=DEEPSEEK_API_KEY

# 2. Full config verdict (reports missing secrets and unknown toolsets):
hermes config check
```

### `Warning: Unknown toolsets: <name>`

**Symptom:** startup prints e.g. `Warning: Unknown toolsets: messaging`, and
`hermes config check` adds `⚠ platform 'cli' references unknown toolset 'messaging'`.

**Cause:** a stale entry in `platform_toolsets.<platform>` in
`%LOCALAPPDATA%\hermes\config.yaml` — here the obsolete bare name `messaging`
listed under both `cli` and `whatsapp`. Hermes toolset names are `hermes-cli`,
`hermes-whatsapp`, etc.; a bare `messaging` is not a valid toolset id, so every
launch re-warns about it.

**Fix (2026-10-24):** removed the `- messaging` entry from `platform_toolsets.cli`
and `platform_toolsets.whatsapp`. The warning is harmless (the session still
starts) but `hermes config check` should report no `⚠` lines after cleanup.

### Chat stuck at `Gateway draining: not_ready`

**Symptom:** the CLI banner sits on `Gateway draining: not_ready` and never
answers.

**Cause:** the last gateway start aborted — `gateway_state.json` shows
`"gateway_state": "startup_failed"` with an `exit_reason` (2026-10-25:
`whatsapp: WhatsApp enabled but not paired` — hermes 0.22.1 treats an
enabled-but-unpaired platform as a *non-retryable startup conflict* and
exits cleanly, so the CLI waits forever).

**Fix:** resolve the platform named in `exit_reason` — either pair it
(`hermes whatsapp`) or disable it (here: `WHATSAPP_ENABLED=false` in `.env`),
then `hermes gateway start`. Verify:

```bash
hermes gateway status        # ✓ Gateway is running
hermes -z "responde solo: hola"
```

### `An Application Control policy has blocked this file` — nothing starts

**Symptom (2026-10-25):** the launcher, `hermes-gateway-reload.sh`, and even
`hermes gateway restart` die instantly:

```
Program 'python.exe' failed to run: An Application Control policy has blocked this file
```

(`Permission denied` when invoked from Git Bash.) A gateway that was already
running keeps serving, but **no new Hermes process can start**.

**Cause:** Smart App Control flipped from *evaluation* to **enforced** (14:28;
`HKLM\SYSTEM\ControlSet001\Control\CI\Policy` →
`VerifiedAndReputablePolicyState: 1`, `SAC_PreviousState: 2`). The venv
interpreter was an **unsigned uv shim** (`venv\Scripts\python.exe`, 45 KB,
`NotSigned`) — tolerated in evaluation mode, blocked once enforced. The
Code Integrity log (`Microsoft-Windows-CodeIntegrity/Operational`, events
3033/3077) names the file and "Enterprise signing level requirements".
This likely explains the earlier `hermes.exe` block noted in commit `7b372f6`.

**Fix (verified 2026-10-25):** swap the shim for uv's *base* `python.exe` —
a binary the control already lets run — and bring its DLLs along:

```powershell
$s    = "C:\Users\e4dev\AppData\Local\hermes\hermes-agent\venv\Scripts"
$base = "C:\Users\e4dev\AppData\Roaming\uv\python\cpython-3.11-windows-x86_64-none"
Copy-Item "$s\python.exe" "$s\python.exe.bak-20261025-sac"   # backup
# If "file in use": rename first — Rename-Item "$s\python.exe" python.exe.blocked-shim
Copy-Item "$base\python.exe" "$s\python.exe" -Force
Copy-Item "$base\*.dll"      "$s" -Force   # python311.dll + CRT — without them: 0xC0000135
```

Verify the venv still activates:

```powershell
& "$s\python.exe" -c "import sys; print(sys.prefix)"   # → the venv path
```

**Caveats:**

- Backups kept: `python.exe.bak-20261025-sac` and `pythonw.exe.bak-20261025-sac`
  (same swap applied to `pythonw.exe`). `python.exe.blocked-shim` is the
  original renamed in place while a pre-swap process still holds it — safe to
  delete after a reboot.
- `hermes update` or a uv Python upgrade may regenerate the unsigned shim →
  re-apply the swap.
- Alternatives: rebuild the venv on a python.org (signed) interpreter, or
  turn Smart App Control off (Windows Security → App & browser control;
  turning it back on requires a Windows reset) — a machine-wide decision
  that was **not** taken here.
