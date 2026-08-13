# Xiaomi MiMo Configuration Guide for Hermes Agent

This guide outlines how to configure **Xiaomi MiMo** models (specifically for Token Plan users) in **Hermes Agent** on Windows.

## File Paths

On Windows, the configuration files are located at:
* **Configuration file:** `C:\Users\e4dev\AppData\Local\hermes\config.yaml`
* **Environment variables:** `C:\Users\e4dev\AppData\Local\hermes\.env`

---

## Configuration Options

Choose one of the following protocols to integrate Xiaomi MiMo into Hermes Agent:

### Option A: OpenAI Compatible Protocol (Recommended)

1. Open `config.yaml` and update the top `model` section:
   ```yaml
   model:
     default: openai/mimo-v2.5-pro
     provider: openai
     base_url: https://token-plan-sgp.xiaomimimo.com/v1
   ```

2. Open `.env` and add your Token Plan API key (should start with `tp-`):
   ```env
   OPENAI_API_KEY=tp-your_token_plan_key_here
   ```

### Option B: Anthropic Compatible Protocol

1. Open `config.yaml` and update the top `model` section:
   ```yaml
   model:
     default: anthropic/mimo-v2.5-pro
     provider: anthropic
     base_url: https://token-plan-sgp.xiaomimimo.com/anthropic
   ```

2. Open `.env` and add your Token Plan API key (should start with `tp-`):
   ```env
   ANTHROPIC_API_KEY=tp-your_token_plan_key_here
   ```

---

## Verification

After saving both files, restart your Hermes Agent session or terminal. You can run the following command to test connectivity:
```powershell
hermes chat --message "Hello"
```
