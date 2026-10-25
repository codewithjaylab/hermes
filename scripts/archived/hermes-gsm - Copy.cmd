@echo off
REM hermes-gsm.cmd — Launch Hermes with API keys from Google Secret Manager
REM
REM Usage (cmd.exe):
REM   hermes-gsm.cmd                        interactive chat
REM   hermes-gsm.cmd -q "pregunta"          single query
REM   hermes-gsm.cmd --resume sesion        resume session
REM
REM Prerequisites:
REM   - gcloud SDK installed and on PATH
REM   - Secrets created in GSM (DEEPSEEK_API_KEY, etc.)
REM   - gcloud auth application-default login (for ADC)

setlocal enabledelayedexpansion

set HERMES_PATH=C:\Users\e4dev\AppData\Local\hermes\hermes-agent\venv\Scripts\hermes.exe

echo [hermes-gsm] Fetching secrets from Google Secret Manager...

REM ── DEEPSEEK_API_KEY ─────────────────────────────────────────
for /f "delims=" %%i in ('gcloud secrets versions access latest --secret^=DEEPSEEK_API_KEY 2^>nul') do (
    set "DEEPSEEK_API_KEY=%%i"
    echo [hermes-gsm]   OK DEEPSEEK_API_KEY loaded
)

REM ── OPENROUTER_API_KEY (uncomment if using OpenRouter) ───────
REM for /f "delims=" %%i in ('gcloud secrets versions access latest --secret^=OPENROUTER_API_KEY 2^>nul') do set "OPENROUTER_API_KEY=%%i"

echo [hermes-gsm] Launching Hermes...
echo.

REM ── Launch Hermes ────────────────────────────────────────────
"%HERMES_PATH%" %*
exit /b %ERRORLEVEL%
