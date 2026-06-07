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
$secrets = @(
    "DEEPSEEK_API_KEY"
    # "OPENROUTER_API_KEY"   # uncomment if using OpenRouter
    # "ANTHROPIC_API_KEY"    # uncomment if using Anthropic direct
    # "GOOGLE_API_KEY"       # uncomment if using Gemini
)

$hermesPath = "C:\Users\e4dev\AppData\Local\hermes\hermes-agent\venv\Scripts\hermes.exe"

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
            Write-Host "[hermes-gsm]   WARN Could not fetch '$secret' — skipping" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[hermes-gsm]   WARN Could not fetch '$secret' — $_" -ForegroundColor Yellow
    }
}

Write-Host "[hermes-gsm] Launching Hermes..." -ForegroundColor Cyan
Write-Host ""

# ── Launch Hermes ──────────────────────────────────────────────
& $hermesPath @args
exit $LASTEXITCODE
