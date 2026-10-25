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
