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
