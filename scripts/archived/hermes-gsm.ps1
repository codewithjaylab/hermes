# hermes-gsm.ps1 — Launch Hermes with API keys from Google Secret Manager
#
# Usage (PowerShell):
#   .\hermes-gsm.ps1                        # interactive chat
#   .\hermes-gsm.ps1 -q "pregunta"          # single query
#   .\hermes-gsm.ps1 --resume sesion        # resume session
#
# Or add to your PowerShell profile ($PROFILE):
#   function hermes { & C:\workspace\hermes\scripts\hermes-gsm.ps1 @args }
#
# Prerequisites:
#   - gcloud SDK installed and on PATH
#   - Secrets created in GSM (DEEPSEEK_API_KEY, etc.)
#   - gcloud auth application-default login (for ADC)

$ErrorActionPreference = "Stop"

# ── Config ─────────────────────────────────────────────────────
# Secrets are read from gsm-secrets.conf (one per line, # for comments)
$configFile = Join-Path $PSScriptRoot "gsm-secrets.conf"

if (Test-Path $configFile) {
    $secrets = Get-Content $configFile | Where-Object {
        $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$'
    } | ForEach-Object { $_.Trim() }
} else {
    Write-Host "[hermes-gsm] ERROR: Config file not found: $configFile" -ForegroundColor Red
    exit 1
}

$pythonExe = "C:\Users\e4dev\AppData\Local\hermes\hermes-agent\venv\Scripts\python.exe"

# ── Fetch secrets from GSM ─────────────────────────────────────
Write-Host "[hermes-gsm] Fetching secrets from Google Secret Manager..." -ForegroundColor Cyan

foreach ($secret in $secrets) {
    try {
        $value = gcloud secrets versions access latest --secret=$secret 2>$null
        if ($LASTEXITCODE -eq 0) {
            # Trim trailing newline that gcloud appends
            $value = $value.TrimEnd("`r", "`n")
            [Environment]::SetEnvironmentVariable($secret, $value, "Process")
            Write-Host "[hermes-gsm]   OK $secret loaded" -ForegroundColor Green
        } else {
            Write-Host "[hermes-gsm]   WARN Could not fetch '$secret' - skipping" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[hermes-gsm]   WARN Could not fetch '$secret' - $_" -ForegroundColor Yellow
    }
}

# ── Check if Headroom proxy is running on port 8787 ────────────
$proxyRunning = Get-NetTCPConnection -LocalPort 8787 -ErrorAction SilentlyContinue
if ($proxyRunning) {
    Write-Host "[hermes-gsm] Headroom proxy detected on port 8787. Routing requests through proxy to save tokens." -ForegroundColor Cyan
    $env:DEEPSEEK_BASE_URL = "http://localhost:8787/v1"
    $env:GEMINI_BASE_URL = "http://localhost:8787/v1beta"
} else {
    Write-Host "[hermes-gsm] Headroom proxy not detected on port 8787. Direct connection will be used." -ForegroundColor DarkGray
}

Write-Host "[hermes-gsm] Launching Hermes..." -ForegroundColor Cyan
Write-Host ""

# ── Launch Hermes ──────────────────────────────────────────────
& $pythonExe -m hermes_cli.main @args
exit $LASTEXITCODE
