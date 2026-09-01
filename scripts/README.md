# Hermes GSM Launchers

A set of wrapper scripts to launch the **Hermes CLI** automatically fetching API keys from **Google Secret Manager (GSM)**.

This prevents storing sensitive API keys in local environment variables or `.env` files.

## Prerequisites

1.  **Google Cloud SDK (gcloud):** Must be installed and available in your `PATH`.
2.  **Authentication:** You must be authenticated with Google Cloud. Run:
    ```bash
    gcloud auth application-default login
    ```
3.  **Secrets in GSM:** Ensure you have the required secrets (e.g., `DEEPSEEK_API_KEY`) created in your Google Cloud Project and that your account has the `Secret Manager Secret Accessor` role.

## Included Scripts

| Platform | Script | Shell |
| :--- | :--- | :--- |
| **Windows** | `hermes-gsm.cmd` | Command Prompt (CMD) |
| **Windows** | `hermes-gsm.ps1` | PowerShell |
| **Linux / macOS / Windows (Git Bash)** | `hermes-gsm.sh` | Bash |
| **Linux / macOS** | `hermes-gsm-ubuntu.sh` | Bash |
| **Any (helper)** | `hermes-gsm-gcloud-logout.sh` | Bash |

## Auto-Logout (gcloud session)

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
function hermes { & "C:\workspace\hermes\scripts\hermes-gsm.ps1" @args }
```

**Bash (`~/.bashrc` or `~/.zshrc`):**
```bash
alias hermes='/path/to/hermes-gsm.sh'

e.g = /c/workspace/hermes/scripts/hermes-gsm.sh
```

## Usage

You can pass any Hermes CLI arguments directly to the scripts.

```bash
# Start an interactive chat
hermes-gsm

# Single query mode
hermes-gsm -q "Explain quantum entanglement"

# Resume a previous session
hermes-gsm --resume my-session-id
```

## Configuration

All three scripts read their secret names from a single flat-file config: **`gsm-secrets.conf`**

To add or remove API keys, edit that file — one secret name per line:

```
# ── API Keys from Google Secret Manager ──
DEEPSEEK_API_KEY
OPENROUTER_API_KEY
NOVITA_API_KEY
# GOOGLE_API_KEY       # commented out — won't be fetched
```

- Lines starting with `#` are comments (ignored)
- Blank lines are ignored
- Changes take effect on next launch — no need to touch the scripts themselves

> **Note:** The scripts assume Hermes is installed at:
> `C:\Users\e4dev\AppData\Local\hermes\hermes-agent\venv\Scripts\hermes.exe`
> If your installation path is different, update the `HERMES_EXE` / `HERMES_PATH` variable inside each script.

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
            "command": "C:/workspace/hermes/scripts/hermes-gsm.cmd",
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
