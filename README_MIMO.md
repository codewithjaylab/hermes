# Xiaomi MiMo Configuration Guide for Hermes Agent (Multi-Provider Setup)

This guide outlines how to configure **Xiaomi MiMo** as a custom provider in **Hermes Agent** alongside your existing providers (OpenRouter, DeepSeek, Google, etc.) on Windows.

## File Paths

On Windows, the configuration files are located at:
* **Configuration file:** `C:\Users\e4dev\AppData\Local\hermes\config.yaml`
* **Environment variables:** `C:\Users\e4dev\AppData\Local\hermes\.env`

---

## Configuration Step-by-Step

To avoid breaking your default models (like OpenRouter or DeepSeek), add Xiaomi MiMo as a custom provider inside the `providers` block.

### 1. Update `config.yaml`

Open `config.yaml` and configure it to match the structure below. Keep your default `model` settings at the top, and add `mimo` under the `providers` key:

```yaml
model:
  default: anthropic/claude-opus-4.6   # Your default OpenRouter model
  provider: auto
  base_url: https://openrouter.ai/api/v1

providers:
  mimo:
    base_url: "https://token-plan-sgp.xiaomimimo.com/v1"
    key_env: "MIMO_API_KEY"
```

### 2. Update `.env`

Open your `.env` file and add the `MIMO_API_KEY` alongside your existing credentials:

```env
MIMO_API_KEY=tp-your_token_plan_key_here
DEEPSEEK_API_KEY=your_deepseek_key_here
OPENROUTER_API_KEY=your_openrouter_key_here
```

*(Note: If you use Google Secret Manager (GSM), make sure to upload `MIMO_API_KEY` as a secret and update your launch script to load it.)*

---

## How to Run Different Models

Now that all providers are configured simultaneously, you can run them using the `--model` flag:

* **Use Default Model (OpenRouter/Claude):**
  ```powershell
  hermes chat
  ```

* **Use Xiaomi MiMo:**
  ```powershell
  hermes chat --model mimo/mimo-v2.5-pro
  ```

* **Use DeepSeek:**
  ```powershell
  hermes chat --model deepseek/deepseek-chat
  ```
