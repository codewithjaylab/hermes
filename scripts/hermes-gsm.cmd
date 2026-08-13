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

REM ── Resolve config file relative to script location ────────────
set SCRIPT_DIR=%~dp0
set CONFIG_FILE=%SCRIPT_DIR%gsm-secrets.conf

if not exist "%CONFIG_FILE%" (
    echo [hermes-gsm] ERROR: Config file not found: %CONFIG_FILE%
    exit /b 1
)

echo [hermes-gsm] Fetching secrets from %CONFIG_FILE%...

REM ── Read secrets from config and fetch from GSM ────────────────
for /f "usebackq eol=# tokens=*" %%s in ("%CONFIG_FILE%") do (
    if not "%%s" == "" (
        for /f "delims=" %%i in ('gcloud secrets versions access latest --secret^=%%s 2^>nul') do (
            set "%%s=%%i"
        )
        if !ERRORLEVEL! EQU 0 (
            echo [hermes-gsm]   OK %%s loaded
        ) else (
            echo [hermes-gsm]   WARN Could not fetch '%%s' -- skipping
        )
    )
)

echo [hermes-gsm] Launching Hermes...
echo.

REM ── Launch Hermes ────────────────────────────────────────────
"%HERMES_PATH%" %*
exit /b %ERRORLEVEL%
