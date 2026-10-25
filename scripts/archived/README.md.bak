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

The scripts are pre-configured to fetch `DEEPSEEK_API_KEY`. To add more secrets (like `OPENROUTER_API_KEY` or `ANTHROPIC_API_KEY`), edit the `SECRETS` array/list inside the scripts and uncomment the relevant lines.

> **Note:** The scripts assume Hermes is installed at:
> `C:\Users\e4dev\AppData\Local\hermes\hermes-agent\venv\Scripts\hermes.exe`
> If your installation path is different, update the `HERMES_EXE` / `HERMES_PATH` variable inside each script.
