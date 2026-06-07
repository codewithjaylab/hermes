# Plan: Proteger API Keys de Hermes con Google Secret Manager

> **Version:** 1.0
> **Autor:** Hermes Agent (DeepSeek v4 Pro)
> **Stack:** Hermes Agent · Google Cloud Secret Manager · gcloud CLI · bash/PowerShell
> **Proposito:** Eliminar API keys en texto plano del `.env` de Hermes usando GSM como source of truth.

---

## 1. El Problema

Hermes guarda sus API keys en `C:\Users\e4dev\AppData\Local\hermes\.env`:

```env
DEEPSEEK_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
OPENROUTER_API_KEY=sk-or-v1-xxxxxxxxxxxxxxxxxxxxxxxx
# ... otras keys
```

Esto presenta riesgos:
- **Robo de disco**: cualquiera con acceso al filesystem lee las keys
- **Exfiltracion por malware**: un script malicioso solo necesita `cat ~/.hermes/.env`
- **Backups/scripts**: las keys viajan en backups, logs, y pantallas compartidas
- **Git accidental**: un `git add .` en el home directory expone las keys

Hermes SI tiene protecciones (secret redaction en tool output, `.env` no legible via `read_file`), pero el archivo en disco sigue siendo texto plano.

---

## 2. Arquitectura Propuesta: Wrapper Script + GSM

### Principio: Hermes no necesita modificarse

Hermes ya sabe leer API keys de variables de entorno. No hay que tocar su codigo interno. En lugar de eso, un **wrapper script** obtiene las keys de GSM y las inyecta como env vars antes de lanzar Hermes.

```
┌─────────────────────────────────────────────────────────────┐
│                     Windows (tu maquina)                      │
│                                                              │
│  ┌──────────────────┐                                        │
│  │  hermes-gsm.sh   │  ← wrapper script                      │
│  │  (pre-launch)    │                                        │
│  └────────┬─────────┘                                        │
│           │                                                   │
│           │  1. gcloud secrets versions access latest         │
│           │     --secret=DEEPSEEK_API_KEY                     │
│           │     --secret=OPENROUTER_API_KEY                   │
│           ▼                                                   │
│  ┌──────────────────┐     ┌──────────────────────────┐       │
│  │  env vars en     │────▶│  hermes (proceso hijo)    │       │
│  │  memoria (RAM)   │     │  lee DEEPSEEK_API_KEY     │       │
│  └──────────────────┘     │  del entorno, no de .env  │       │
│                           └──────────────────────────┘       │
│                                                              │
│  ┌──────────────────┐                                        │
│  │ Google Cloud      │  ← las keys REALES viven aqui         │
│  │ Secret Manager    │     IAM-protegidas, auditadas,        │
│  │ (GSM)             │     versionadas, rotables             │
│  └──────────────────┘                                        │
│                                                              │
│  Autenticacion: ADC (gcloud auth application-default login)  │
│  → %APPDATA%\gcloud\application_default_credentials.json     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Por que este diseno y no modificar Hermes internamente

| Criterio | Wrapper Script | Modificar credential_pool.py |
|----------|---------------|------------------------------|
| Complejidad | Baja (~30 lineas de bash) | Alta (nuevo `credential_source`, tests, PR) |
| Mantenimiento | Independiente de versiones de Hermes | Se rompe con cada update de Hermes |
| Seguridad | Keys en RAM del proceso hijo solamente | Keys pasan por el runtime de Python |
| Multi-key | Soporta cualquier provider automaticamente | Hay que registrar cada provider |
| Rollback | Borrar el alias y listo | Revertir cambios de codigo |

---

## 3. Implementacion Paso a Paso

### 3.1 Crear los secretos en GSM

```bash
# Para cada API key que quieras proteger:

# DeepSeek
echo -n "sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" | \
  gcloud secrets create DEEPSEEK_API_KEY \
    --replication-policy=automatic \
    --data-file=-

# OpenRouter (si aplica)
echo -n "sk-or-v1-xxxxxxxxxxxxxxxxxxxxxxxx" | \
  gcloud secrets create OPENROUTER_API_KEY \
    --replication-policy=automatic \
    --data-file=-

# Verificar
gcloud secrets list
gcloud secrets versions access latest --secret=DEEPSEEK_API_KEY
```

### 3.2 Configurar IAM (minimo privilegio)

```bash
# La cuenta que ejecuta el wrapper necesita solo secretAccessor
gcloud projects add-iam-policy-binding brave-monitor-498704-c0 \
  --member="user:devopsmentor.io@gmail.com" \
  --role="roles/secretmanager.secretAccessor"
```

### 3.3 Crear el wrapper script

**Archivo: `C:\workspace\hermes\scripts\hermes-gsm.sh`**

```bash
#!/usr/bin/env bash
# hermes-gsm.sh — Launch Hermes with API keys from Google Secret Manager
#
# Usage:
#   hermes-gsm                    # interactive chat
#   hermes-gsm -q "pregunta"      # single query
#   hermes-gsm --resume sesion    # resume session
#
# Prerequisites:
#   - gcloud SDK installed and authenticated (gcloud auth application-default login)
#   - Secrets created in GSM (DEEPSEEK_API_KEY, OPENROUTER_API_KEY, etc.)

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────
# Lista de secretos a inyectar como variables de entorno.
# Agrega o quita segun los providers que uses.
SECRETS=(
    "DEEPSEEK_API_KEY"
    "OPENROUTER_API_KEY"
    # "ANTHROPIC_API_KEY"
    # "GOOGLE_API_KEY"
)

# ── Fetch secrets from GSM ─────────────────────────────────────
echo "[hermes-gsm] Fetching secrets from Google Secret Manager..."

for secret_name in "${SECRETS[@]}"; do
    value=$(gcloud secrets versions access latest \
        --secret="$secret_name" 2>/dev/null) || {
        echo "[hermes-gsm] WARNING: Could not fetch secret '$secret_name' — skipping"
        continue
    }
    export "$secret_name=$value"
    echo "[hermes-gsm]   ✓ $secret_name loaded"
done

echo "[hermes-gsm] Launching Hermes..."
echo ""

# ── Launch Hermes ──────────────────────────────────────────────
# Pasa todos los argumentos al comando hermes
exec hermes "$@"
```

**Version PowerShell (alternativa): `C:\workspace\hermes\scripts\hermes-gsm.ps1`**

```powershell
# hermes-gsm.ps1 — Launch Hermes with API keys from Google Secret Manager

$ErrorActionPreference = "Stop"

$secrets = @(
    "DEEPSEEK_API_KEY"
    "OPENROUTER_API_KEY"
)

Write-Host "[hermes-gsm] Fetching secrets from Google Secret Manager..."

foreach ($secret in $secrets) {
    try {
        $value = gcloud secrets versions access latest --secret=$secret 2>$null
        if ($LASTEXITCODE -eq 0) {
            [Environment]::SetEnvironmentVariable($secret, $value, "Process")
            Write-Host "[hermes-gsm]   ✓ $secret loaded"
        } else {
            Write-Host "[hermes-gsm] WARNING: Could not fetch $secret — skipping"
        }
    } catch {
        Write-Host "[hermes-gsm] WARNING: Could not fetch $secret — skipping"
    }
}

Write-Host "[hermes-gsm] Launching Hermes..."
Write-Host ""

# Launch Hermes with all original arguments
& hermes @args
```

### 3.4 Crear alias para uso diario

En `~/.bashrc` (Git Bash):

```bash
# Alias para lanzar Hermes con GSM
alias hermes='~/workspace/hermes/scripts/hermes-gsm.sh'
```

O en PowerShell profile:

```powershell
function hermes { & C:\workspace\hermes\scripts\hermes-gsm.ps1 @args }
```

### 3.5 Limpiar el .env actual

Despues de verificar que el wrapper funciona:

1. Quitar `DEEPSEEK_API_KEY` y `OPENROUTER_API_KEY` de `~/.hermes/.env`
2. Dejar solo configuracion no-sensible (ej: `BRAVE_API_KEY` si es gratis, vars de config)

```bash
# Editar .env (Hermes protege la lectura directa, hay que usar el terminal)
hermes config edit   # o directamente editar el archivo
```

---

## 4. Verificacion

### 4.1 Smoke test

```bash
# 1. Verificar que ADC funciona
gcloud auth application-default print-access-token > nul && echo "ADC OK" || echo "ADC FAIL"

# 2. Verificar que los secretos son accesibles
gcloud secrets versions access latest --secret=DEEPSEEK_API_KEY > nul && echo "GSM OK"

# 3. Lanzar Hermes via wrapper
hermes-gsm.sh -q "responde 'ok' si puedes leer este mensaje"
```

### 4.2 Check de seguridad

```bash
# Verificar que DEEPSEEK_API_KEY NO esta en el .env
cat ~/.hermes/.env | grep DEEPSEEK || echo "✓ Key no esta en .env"

# Verificar que el proceso Hermes SI tiene la key en RAM
# (dificil de verificar sin ser root — es la idea)
```

---

## 5. Seguridad: Analisis de Riesgos

### Lo que este plan SOLUCIONA

| Riesgo | Antes | Despues |
|--------|-------|---------|
| Key en disco (robo fisico / malware basic) | Texto plano en `.env` | Solo en GSM (IAM-protegido) |
| Key en backups | Backups incluyen `.env` | `.env` no tiene keys |
| Key en logs accidentales | Puede aparecer en stdout/stderr | GSM → RAM del proceso hijo → no toca disco |
| Key compartida en pantalla | `cat .env` muestra todo | Necesita acceso a GSM + IAM |
| Rotacion de keys | Editar `.env` manualmente | `gcloud secrets versions add` desde CLI |

### Lo que este plan NO soluciona

| Riesgo | Explicacion | Mitigacion adicional |
|--------|-------------|---------------------|
| Key en RAM del proceso | Un atacante con acceso al proceso Hermes puede leer `/proc/<pid>/environ` en Linux | Es inherente — Hermes necesita la key para llamar a la API. No hay solucion sin HSM/TPM. |
| Key en memoria de Python | `os.environ` es legible desde el mismo proceso | Hermes ya tiene `security.redact_secrets: true` |
| ADC token robado | `%APPDATA%\gcloud\application_default_credentials.json` es un refresh token que puede usarse para llamar a GSM | Proteger el archivo ADC con permisos NTFS; usar Service Account en produccion |
| Key viaja a DeepSeek/OpenRouter | La key se envia por HTTPS a la API del provider | Es inevitable — el provider la necesita. Usar keys con scope limitado. |

### Por que GSM y no .env encriptado / Bitwarden / HashiCorp Vault

| Alternativa | Pros | Contras |
|-------------|------|---------|
| `.env` con `sops` | Simple, cifrado AGE/GPG/KMS | Requiere desencriptar a disco; la key desencriptada toca filesystem |
| Bitwarden Secrets | Hermes ya tiene soporte (`secrets.bitwarden` en config) | Requiere servidor Bitwarden externo o cuenta cloud |
| HashiCorp Vault | Enterprise-grade, audit log | Overkill para dev local; requiere servidor Vault corriendo |
| **GSM (elegido)** | Ya tenes GCP + ADC configurado; IAM nativo; sin infra extra | Depende de conectividad a GCP (mitigado con cache local opcional) |

---

## 6. Roadmap: de Minimal Viable a Produccion

### Fase 1 — MVP (15 min)
- [x] Crear secretos en GSM para DEEPSEEK_API_KEY, OPENROUTER_API_KEY
- [x] Verificar ADC funciona (`gcloud auth application-default print-access-token`)
- [ ] Crear `hermes-gsm.sh` wrapper
- [ ] Probar que Hermes arranca via wrapper
- [ ] Quitar keys del `.env`

### Fase 2 — Robustez (30 min)
- [ ] Agregar cache local opcional (evita llamada a GSM en cada launch):
  ```bash
  # Guardar en ramdisk o directorio con permisos restringidos
  CACHE_FILE="$HOME/.hermes/.gsm_cache"
  # TTL: 1 hora (las keys de API no cambian seguido)
  ```
- [ ] Agregar timeout + retry a las llamadas gcloud
- [ ] Mensajes de error claros si ADC no esta configurado
- [ ] Version PowerShell del wrapper para compatibilidad nativa Windows

### Fase 3 — Multiples Providers (futuro)
- [ ] Soportar ANTHROPIC_API_KEY, GOOGLE_API_KEY, etc.
- [ ] Configuracion por perfil de Hermes (diferentes GSM secrets segun `--profile`)
- [ ] Integracion con `hermes auth` como credential source ("gsm")

### Fase 4 — Produccion / CI (futuro)
- [ ] Service Account dedicada (`hermes-sa@...`) en lugar de user credentials
- [ ] Cloud Run / GKE: montar secrets como volumenes o usar metadata server
- [ ] Rotacion automatica de keys con Cloud Scheduler + Cloud Functions

---

## 7. Alternativa: Integracion Nativa en Hermes (credential source "gsm")

Para referencia futura, Hermes se puede extender con un nuevo credential source. Esto requeriria:

1. Agregar `_seed_from_gsm()` en `agent/credential_pool.py`
2. Registrar `RemovalStep` en `agent/credential_sources.py` con `source_id="gsm"`
3. Agregar comando `hermes auth add gsm` en `hermes_cli/auth.py`

El source leería de GSM usando ADC y poblaría el credential pool. Ventajas:
- Multi-key automatico (todas las keys de un provider desde GSM)
- Integrado con `hermes auth list / remove`
- Credential pool strategies (round_robin, fill_first) funcionarian con keys de GSM

**No recomendado para MVP** — el wrapper script es suficiente y no requiere modificar Hermes.

---

## 8. Referencias

- [Hermes Agent — Credential Pool](https://github.com/NousResearch/hermes-agent/blob/main/agent/credential_pool.py)
- [Hermes Agent — Config docs](https://hermes-agent.nousresearch.com/docs/user-guide/configuration)
- [Hermes Agent — Secrets config](https://hermes-agent.nousresearch.com/docs/user-guide/features/secrets)
- [Google Secret Manager — Access via gcloud](https://cloud.google.com/secret-manager/docs/access-secret-version)
- [gcloud auth application-default login](https://cloud.google.com/sdk/gcloud/reference/auth/application-default/login)
- [ADC en Windows](https://cloud.google.com/docs/authentication/application-default-credentials#Windows)

---

> **Fin del plan.** MVP: ~15 min para tener Hermes corriendo sin API keys en disco.
> El wrapper script esta disenado para ser reemplazado por integracion nativa si Hermes
> adopta GSM como credential source en el futuro.
