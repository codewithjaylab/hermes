# Hermes Agent — GSM Integration

This repo contains scripts and configuration for integrating Hermes Agent with **Google Secret Manager (GSM)**.

## Quick Start

```bash
# Linux/macOS
./scripts/hermes-gsm.sh

# Windows (Git Bash)
bash scripts/hermes-gsm.sh

# Windows (PowerShell)
powershell -File scripts/hermes-gsm.ps1
```

## Structure

- **`docs/`** — Architecture and design plans
- **`scripts/`** — Cross-platform GSM management scripts (cmd, ps1, sh)
- **`hermes_setup.md`** — Hermes agent setup guide
- **`plan-hermes-gsm-api-keys.md`** — API key management plan

## Prerequisites

- Google Cloud SDK (`gcloud`) installed and authenticated
- Hermes Agent installed
- Appropriate GCP permissions for Secret Manager

## Configuring the Default Model

Hermes supports 20+ providers. You can switch the default model at any time.

### Option 1: Interactive picker (recommended)

```bash
hermes model
```

This launches an interactive wizard where you select provider and model.

### Option 2: Direct config commands

**Set MiMo v2.5-pro (Xiaomi) as default:**

```bash
# 1. Add your Xiaomi API key
hermes auth add xiaomi
# Or manually add to ~/.hermes/.env:
#   XIAOMI_API_KEY=your-key-here

# 2. Set model and provider
hermes config set model.default mimo-v2.5-pro
hermes config set model.provider xiaomi
```

**Set any other model (examples):**

```bash
# Claude Sonnet 4 via Anthropic
hermes config set model.default claude-sonnet-4
hermes config set model.provider anthropic

# GPT-4o via OpenAI
hermes config set model.default gpt-4o
hermes config set model.provider openai

# DeepSeek V3
hermes config set model.default deepseek-chat
hermes config set model.provider deepseek

# Any model via OpenRouter (single key, many models)
hermes config set model.default anthropic/claude-sonnet-4
hermes config set model.provider openrouter
```

### Option 3: Edit config.yaml directly

```bash
hermes config edit
```

Modify the `model` section:

```yaml
model:
  default: mimo-v2.5-pro
  provider: xiaomi
```

After changing the model, restart the CLI or start a new session for the
change to take effect.

## Rolling Back to Anthropic Claude (Default)

If you customized the model and want to revert to the Hermes default
(Anthropic Claude), follow these steps:

### Step 1: Remove custom model config

```bash
# Unset the custom model and provider
hermes config set model.default ""
hermes config set model.provider ""
```

Or edit `~/.hermes/config.yaml` directly and remove or comment out the
`model.default` and `model.provider` lines:

```yaml
model:
  # default: mimo-v2.5-pro    # <-- remove or comment out
  # provider: xiaomi           # <-- remove or comment out
```

### Step 2: Ensure Anthropic API key is set

```bash
# Check if key exists
hermes auth list

# If missing, add it
hermes auth add anthropic
# Or manually add to ~/.hermes/.env:
#   ANTHROPIC_API_KEY=sk-ant-your-key-here
```

### Step 3: Verify

```bash
hermes config        # Should show no custom model override
hermes doctor        # Check everything is healthy
hermes chat -q "What model are you?"   # Quick test
```

Hermes will fall back to its built-in default (Anthropic Claude) when no
custom model is configured.
