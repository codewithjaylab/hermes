# Hermes — Default Model Init (deepseek-v4-flash)

Setup notes for forcing Hermes Agent to always load **deepseek-v4-flash** (provider: **deepseek**) as the default model on session start.

## Objective

Make every new Hermes session start with `deepseek-v4-flash` from the `deepseek` provider, without needing `/model` or `--model` flags at launch time.

## What was changed

The model defaults were persisted in the main Hermes config file using the official CLI (never hand-edit `config.yaml`):

```bash
hermes config set model.default deepseek-v4-flash
hermes config set model.provider deepseek
```

Resulting settings:

| Key               | Value             |
| :---------------- | :---------------- |
| `model.default`   | `deepseek-v4-flash` |
| `model.provider`  | `deepseek`        |

Config file location:

```
~/.hermes/config.yaml          # Linux/macOS
%USERPROFILE%\.hermes\config.yaml   # Windows
```

## Verification

```bash
# Show the resolved default model + provider
hermes config get model.default
hermes config get model.provider

# Full config view
hermes config show

# Interactive confirmation (starts a session and shows the model header)
hermes
```

A fresh session prints the model in its startup header: `Model: deepseek-v4-flash · Provider: deepseek`.

## Behavior notes

- The change applies to **new sessions only**; already-running sessions keep their current model (prompt-caching invariant — never swap mid-conversation).
- Session-scoped overrides still work: `/model <name>` switches for the current chat, and `hermes chat --model <name>` overrides for a single run. The `model.default` value is only the fallback/startup model.
- Subagents spawned via `delegate_task` inherit the parent model unless `delegation.model` / `delegation.provider` are pinned in config.
- API key is read from `DEEPSEEK_API_KEY` (`.env` / environment). In this setup the key is injected at launch by the GSM wrapper scripts (`hermes-gsm.*` + `gsm-secrets.conf`) instead of being stored locally.

## zsh alias — `hermes` → `hermes-gsm-ubuntu.sh`

The `hermes` command is overridden in the interactive shell so every launch first fetches API keys from Google Secret Manager (GSM) and then executes the real Hermes binary.

### What was changed

Added to `~/.zshrc` (under the existing `# Aliases` block):

```bash
# Hermes: override 'hermes' to fetch API keys from Google Secret Manager first
alias hermes='/home/sdkjqg/workspace/hermes-sdkjqg/hermes/scripts/hermes-gsm-ubuntu.sh'
```

Applied with the `patch` tool (targeted replace of the `# Aliases` block in `~/.zshrc`).

### How it works

1. `hermes` (any form: `hermes`, `hermes -q "..."`, `hermes --resume <id>`) expands to the wrapper script.
2. `hermes-gsm-ubuntu.sh` reads the secret names from `gsm-secrets.conf` (same directory), fetches each via `gcloud secrets versions access latest`, and exports them as env vars (e.g. `DEEPSEEK_API_KEY`).
3. It resolves the real executable with `command -v hermes` (falls back to common install paths), then `exec`s it with the original arguments: `exec "$HERMES_EXE" "$@"`.

No recursion: the alias only expands in the interactive zsh shell, not inside the bash script, so `command -v hermes` finds the real binary on `PATH` (`/home/sdkjqg/workspace/Hermes-Agent/venv/bin/hermes`).

### Verification

```bash
# Confirm the alias resolves correctly (interactive zsh)
zsh -ic 'alias hermes'
# → hermes=/home/sdkjqg/workspace/hermes-sdkjqg/hermes/scripts/hermes-gsm-ubuntu.sh

# Reload config in the current terminal, then launch
source ~/.zshrc
hermes
```

Expected output on launch:

```
[hermes-gsm] Fetching secrets from Google Secret Manager...
[hermes-gsm]   OK DEEPSEEK_API_KEY loaded
[hermes-gsm] Launching Hermes...
```

### Reverting

```bash
# Remove the alias line from ~/.zshrc, then reload
sed -i '/alias hermes=.*hermes-gsm-ubuntu.sh/d' ~/.zshrc
source ~/.zshrc
```

### Prerequisites

- `gcloud` SDK on `PATH` and authenticated (`gcloud auth application-default login`).
- Secrets created in GSM and the account granted `Secret Manager Secret Accessor`.
- `gsm-secrets.conf` present next to the script with one secret name per line.

## Reverting

```bash
hermes config unset model.default
hermes config unset model.provider
```

## Prerequisites

- Hermes Agent installed (git install or shell installer).
- Valid DeepSeek credentials available at launch time (`DEEPSEEK_API_KEY` or GSM-injected key).
