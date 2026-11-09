# Hermes en esta máquina (Ryzen 3) — configuración, plugins y secretos en Google Secret Manager

> **Máquina:** Windows 11, usuario `e4dev` · **Hermes:** v0.22.1+48.g379cf12 (2026.9.24),
> instalación por git · **Python:** 3.11.15 (venv propio) · **Última verificación:** 2026-11-08
>
> Documento de referencia del estado **real** de esta instalación, con foco en cómo Hermes
> obtiene sus API keys desde **Google Secret Manager (GSM)** mediante el plugin `gsm`, sin
> guardarlas en `~/.hermes/.env`.

---

## 0. TL;DR

| Pieza | Dónde | Estado |
|---|---|---|
| Instalación de Hermes | `C:\Users\e4dev\AppData\Local\hermes\hermes-agent` | v0.22.1+48, `git`, Python 3.11.15 en `venv/Scripts` |
| Config | `~/.hermes\config.yaml` (`C:\Users\e4dev\AppData\Local\hermes\config.yaml`) | 645 líneas, `_config_version: 51` |
| Secretos de usuario | `~/.hermes\.env` | 20 variables, **ninguna API key** |
| Plugins instalados | `~/.hermes\plugins\` | `gsm` (local, 1.0.0) y `homeassistant` (catálogo oficial, 2.0.1) |
| Origen de las API keys | **plugin `gsm`** → `gcloud` → GSM (`brave-monitor-498704-c0`) | funcionando, verificado |
| Modelo / proveedor | `deepseek-v4-flash` / `deepseek` (`key_env: DEEPSEEK_API_KEY`) | key llega desde GSM |
| Gateway | `hermes gateway run`, WhatsApp **connected** (PID 16776 al cerrar este doc) | `127.0.0.1:3000` (bridge Baileys) |
| Vigilante | tarea `HermesGatewayWatchdog`, cada 1 min | revive el gateway solo (`wake.log`) |
| Prueba del source | `scripts/verify-gsm-source.py` | `[OK] gsm: applied=['DEEPSEEK_API_KEY']` |

Regla mental: **el `.env` define configuración; el plugin `gsm` define credenciales.**
El proceso que habla con el modelo (gateway, CLI, cron) resuelve sus llaves al arrancar,
desde GSM, y las mantiene solo en memoria.

---

## 1. Rutas y arranque

```
C:\Users\e4dev\AppData\Local\hermes\        ← HERMES_HOME
├── config.yaml            configuración (modelo, plugins, secrets, plataformas)
├── .env                   20 variables; sin API keys
├── auth.json              credenciales OAuth (Nous); no se usa para DeepSeek
├── gateway.pid            {"pid": 16776, "kind": "hermes-gateway", ...}
├── gateway_state.json     platforms.whatsapp.state = "connected"
├── hermes-agent\          código + venv\Scripts\python.exe (3.11.15)
├── plugins\
│   ├── gsm\               plugin local: secret source de Google Secret Manager
│   ├── homeassistant\     plugin del catálogo oficial (pinned ba30cb0c)
│   └── .install-metadata.json
├── skills\                skills instaladas (devops, github, productivity, ...)
├── logs\                  agent.log, errors.log, gateway-stdio.log
└── cache\                 scratch/ y, si se activa TTL, gsm_cache.json
```

Hay **dos caminos de arranque** y conviene no confundirlos:

1. **Launcher con inyección de entorno** — `~/bin/hermes.cmd` →
   `C:\workspace\hermes\scripts\hermes-gsm.cmd` / `hermes-gsm-git-bash-win.sh`.
   Lee `scripts/gsm-secrets.conf`, ejecuta `gcloud secrets versions access latest ...`
   y **exporta** cada valor antes de lanzar el CLI. Sirve para sesiones interactivas
   arrancadas a mano.
2. **Gateway** — proceso persistente (`hermes gateway run`) que atiende WhatsApp/Telegram.
   **No hereda el entorno del shell** donde se lanzó el launcher; si necesita una key la
   resuelve por el **secret source del plugin**. Por eso el plugin no es un adorno: es la
   única vía que cubre gateway y cron.

> En esta máquina el gateway corre con WhatsApp conectado (PID 16776 al escribir esto) y la
> tarea `HermesGatewayWatchdog` lo levanta sola si se cae (§6.5). El editor de
> configuración es `hermes config edit` (no editar `config.yaml` desde una sesión de agente:
> las herramientas de archivo lo rechazan a propósito).

---

## 2. Configuración actual, sección por sección

Solo lo relevante (valores reales, sin secretos):

| Sección | Valor actual | Nota |
|---|---|---|
| `model` | `default: deepseek-v4-flash`, `provider: deepseek`, `base_url: ''` | `providers.deepseek.key_env: DEEPSEEK_API_KEY` |
| `providers` | `deepseek` → `https://api.deepseek.com/v1`; `mimo` → `https://token-plan-sgp.xiaomimimo.com/v1` | `key_env` por proveedor |
| `agent` | `max_turns: 150`, `gateway_timeout: 1800`, `api_max_retries: 3`, `tool_use_enforcement: auto` | `environment_probe: true` |
| `toolsets` | `hermes-cli` | bundle base del CLI |
| `platform_toolsets.cli` | browser, clarify, code_execution, computer_use, connections, cronjob, delegation, file, image_gen, memory, session_search, skills, terminal, todo, tts, vision, web | 17 toolsets |
| `platform_toolsets.whatsapp` | la misma lista | WhatsApp tiene paridad con el CLI |
| `platforms.whatsapp` | `enabled: true`, home channel `58193233346797@lid` | bridge en `127.0.0.1:3000` |
| `plugins.enabled` | `gsm`, `homeassistant` | opt-in: nada se carga si no está acá |
| `plugins.entries.gsm` | `allow_tool_override: false` | el plugin no pisa tools del core |
| `secrets.gsm` | `enabled: true`, `secrets_file: C:/workspace/hermes/scripts/gsm-secrets.conf`, `cache_ttl_seconds: 0`, `override_existing: true` | ver §5 |
| `secrets.bitwarden` | `enabled: false` | builtin, apagado |
| `security.redact_secrets` | `true` | los valores se redactan en tool output |
| `telemetry.shared_metrics` | `enabled: false`, `send: false` | sin telemetría |
| `image_gen` | `use_gateway: true`, `model: fal-ai/flux-2/klein/9b` | |
| `_config_version` | `51` | lo usa `hermes config migrate` |

---

## 3. Plugins: qué son y cómo se cargan

Un plugin es un directorio bajo `~/.hermes/plugins/<nombre>/` con:

- **`plugin.yaml`** — manifiesto (`name`, `label`, `kind`, `version`, `author`, `description`,
  `provides_tools`, `provides_hooks`).
- **`__init__.py`** — implementación; expone `register(ctx)` y llama a métodos de `ctx`
  (`ctx.register_secret_source(...)`, `ctx.register_tool(...)`, etc.).

Se cargan **solo** si están en `plugins.enabled` (opt-in). Los instalados desde el catálogo
guardan pin/revisión en `.install-metadata.json` y quedan fijados a un commit.

Estado real (`hermes plugins list --plain --no-bundled`):

```
enabled      user     1.0.0    gsm
enabled      catalog:official@ba30cb0c 2.0.1    homeassistant
```

| Plugin | Origen | Aporta | Config |
|---|---|---|---|
| `gsm` | local (`author: local`) | **secret source** `gsm` (`provides_tools: []`) | `secrets.gsm` + `plugins.entries.gsm` |
| `homeassistant` | `github.com/NousResearch/hermes-homeassistant` @ `ba30cb0c` | toolset `homeassistant` (`ha_list_entities`, `ha_get_state`, `ha_call_service`, …) sobre la API REST de HA | `known_plugin_toolsets` lo habilita en `cli` y `whatsapp` |

Agregar un plugin nuevo: copiar el directorio a `plugins/`, agregar el nombre a
`plugins.enabled` y reiniciar el proceso (el CLI al relanzarse; el gateway con
`hermes gateway restart`). Deshabilitar: sacarlo de la lista (no hace falta borrar archivos).

---

## 4. Cómo el core resuelve secretos (antes del plugin)

`agent/secret_sources/base.py` define el contrato `SecretSource`:

- Se ejecuta **al arranque**, **después** de cargar `~/.hermes/.env` y **antes** de que el
  resto de Hermes lea `os.environ`. Un `fetch()` por proceso y por `HERMES_HOME`.
- Es **read-only**, **sin prompts** y **nunca lanza**: los errores vuelven en
  `FetchResult.error` con un `ErrorKind`.
- `fetch()` devuelve qué *podría* aportar (`FetchResult.secrets`); el **orquestador**
  (`agent/secret_sources/registry.py::apply_all`) decide qué se aplica y deja **provenance**.

Precedencia que aplica el registry:

1. Dentro de cada *shape*, gana el orden de `secrets.sources` (o el de registro) — el primero
   que reclama una variable se la queda (`skipped_claimed`).
2. `shape: mapped` (binding explícito, como GSM) **vence** a `shape: bulk`.
3. `override_existing: true` permite **pisar** un valor que ya venía del `.env`/shell;
   con `false` la variable existente gana (`skipped_existing`).
4. Nunca se pisan las variables *protegidas* del propio backend (su token de bootstrap) ni
   una variable ya reclamada por otro source.
5. `timeout_seconds` (default 120 s) acota el `fetch()` completo por reloj de pared.

Cada `SourceReport` deja el detalle: `applied`, `skipped_existing`, `skipped_claimed`,
`skipped_protected`, `skipped_invalid`, `warnings`, `error`/`error_kind`.

Taxonomía de errores (`ErrorKind`) y qué implica:

| Kind | Significado | Remedio típico |
|---|---|---|
| `not_configured` | `enabled: true` sin ids de secretos | agregar `secrets` o `secrets_file` |
| `binary_missing` | no se encontró `gcloud` | instalar Cloud SDK o `binary_path` |
| `auth_failed` | credenciales rechazadas (401/403) | `gcloud auth login` / revisar IAM |
| `auth_expired` | credenciales vencidas | `gcloud auth login` otra vez |
| `ref_invalid` | el id del secreto no existe o no tiene versiones | corregir el id / crearlo |
| `network` | no llega a `secretmanager.googleapis.com` | revisar red/proxy |
| `empty_value` | el secreto existe pero sin valor | agregar una versión con datos |
| `timeout` | `gcloud` tardó más de lo permitido | subir `cli_timeout_seconds` |
| `internal` | otra cosa | correr el comando a mano para ver el error real |

Caché (`agent/secret_sources/_cache.py`): dos capas (memoria + disco en
`<HERMES_HOME>/cache/<source>_cache.json`, modo `0600`, directorio `0700`) que **solo**
existen si `cache_ttl_seconds > 0`; con `0` se **desactivan ambas** (comportamiento actual).
Un lote **parcial** no se cachea, para reintentar el secreto faltante en el próximo arranque.

---

## 5. El plugin `gsm` en detalle

Archivos:

```
~/.hermes/plugins/gsm/
├── plugin.yaml     name: gsm · label: Google Secret Manager · kind: standalone
│                   version: 1.0.0 · author: local · provides_tools: [] · provides_hooks: []
└── __init__.py     GsmSource(SecretSource) + register(ctx)
```

### 5.1 Flujo de una lectura

1. `register(ctx)` → `ctx.register_secret_source(GsmSource())` (solo si `gsm` está en
   `plugins.enabled`).
2. Al arrancar, `load_hermes_dotenv()` carga `.env` y luego `apply_all(secrets_cfg, home)`.
   El core re-lee los sources de plugin después del descubrimiento, así que el registro tardío
   no se pierde.
3. `GsmSource.fetch(cfg, home)`:
   a. Junta ids de `secrets.gsm.secrets` **y** de `secrets.gsm.secrets_file`
      (una línea por id, `#` comenta, se ignoran líneas vacías, se deduplica).
   b. Valida que cada id sea **nombre de variable de entorno** (`^[A-Za-z_][A-Za-z0-9_]*$`);
      lo que no lo sea se descarta con warning (`ai-api-key` cae acá).
   c. Resuelve `gcloud` con `binary_path` o `PATH` (acá: `...\google-cloud-sdk\bin\gcloud.CMD`).
   d. Valida `project_id` si está seteado (vacío = **proyecto activo** de gcloud).
   e. Consulta la caché (con TTL 0 no hay).
   f. Lee en paralelo (hasta 8 hilos) cada secreto:
      `gcloud secrets versions access latest --secret=<ID> [--project=<P>]`.
      El hijo corre con entorno **mínimo**: `PATH`, `HOME`, `USERPROFILE`, `SYSTEMROOT`,
      `TMPDIR`, `TEMP`, `LANG`, `LC_ALL`, `XDG_*` + `APPDATA`, `LOCALAPPDATA`,
      `CLOUDSDK_CONFIG` (gcloud necesita su config para las credenciales de usuario),
      `NO_COLOR=1`, `stdin=/dev/null`, stderr sin ANSI.
   g. Devuelve `FetchResult` con valores; si **todo** falla → `error` + `error_kind`; si falla
      **parte** → aplica lo que anduvo y deja `warnings`.
4. El registry aplica los valores a `os.environ` (con `override_existing: true` pisa lo que
   hubiera del `.env`), registra provenance y sigue el arranque.

### 5.2 Opciones (`secrets.gsm`)

| Clave | Default | Para qué |
|---|---|---|
| `enabled` | `false` | interruptor maestro (acá: `true`) |
| `secrets` | `[]` | lista de ids; **cada id nombre de env var** |
| `secrets_file` | `''` | archivo con un id por línea (acá apunta al repo) |
| `project_id` | `''` | GCP project; vacío = proyecto activo de gcloud |
| `binary_path` | `''` | ruta a `gcloud` si no está en `PATH` |
| `cache_ttl_seconds` | `0` | `0` = sin caché (memoria y disco); >0 cachea con `0600` |
| `cli_timeout_seconds` | `30` | timeout de **cada** llamada a gcloud |
| `override_existing` | `true` | GSM pisa `.env`/shell |

### 5.3 Configuración real de esta máquina

`~/.hermes/config.yaml`:

```yaml
plugins:
  enabled:
    - gsm
    - homeassistant
  entries:
    gsm:
      allow_tool_override: false

secrets:
  gsm:
    enabled: true
    secrets_file: C:/workspace/hermes/scripts/gsm-secrets.conf
    cache_ttl_seconds: 0
    override_existing: true
```

`C:\workspace\hermes\scripts\gsm-secrets.conf` (una key activa; el resto comentadas):

```
DEEPSEEK_API_KEY
#OPENROUTER_API_KEY
#NOVITA_API_KEY
# ANTHROPIC_API_KEY
#GOOGLE_API_KEY
#MIMO_API_KEY
#SUDO_PASSWORD
```

### 5.4 Qué hay del otro lado (GSM)

- **Proyecto activo:** `brave-monitor-498704-c0` (config no setea `project_id`, así que usa este).
- **Cuenta gcloud:** `devopsmentor.io@gmail.com` (credenciales **de usuario**, no ADC).
- **SDK:** Google Cloud SDK 571.0.0.
- **Secretos existentes (solo nombres):** `DEEPSEEK_API_KEY`, `FREELLMAPI_KEY`, `GOOGLE_API_KEY`,
  `MIMO_API_KEY`, `NOVITA_API_KEY`, `OPENROUTER_API_KEY`, `SUDO_PASSWORD`, `ai-api-key`.

IAM: el plugin no maneja credenciales propias; hereda las del usuario que corrió
`gcloud auth login`. Basta con `roles/secretmanager.secretAccessor` sobre el proyecto para
leer los valores y **ningún permiso de escritura**.

### 5.5 Propiedades de seguridad

- Las llaves **no viven** en `.env` ni en `config.yaml`; solo en GSM.
- Con `cache_ttl_seconds: 0` **no** se escribe ningún archivo con valores (este equipo).
- El subproceso de `gcloud` recibe un entorno mínimo (no ve las demás variables del proceso).
- `stdin` cerrado: si `gcloud` quisiera pedir algo, falla en vez de colgarse.
- `security.redact_secrets: true` enmascara valores en tool output y logs.
- Límite honesto: cualquier proceso corriendo como el mismo usuario puede ejecutar `gcloud` y
  leer los secretos. Esto reduce la superficie (no hay copias en disco, no hay `.env` con
  llaves), no reemplaza el aislamiento de la cuenta.

---

## 6. Operaciones

### 6.1 Agregar una API key nueva

```bash
# 1) Crear el secreto en GSM (nombre = nombre de la variable de entorno)
gcloud.cmd secrets create OPENROUTER_API_KEY --replication-policy=automatic \
  --project=brave-monitor-498704-c0

# 2) Cargar el valor sin dejarlo en el historial del shell
printf '%s' "$VALOR" | gcloud.cmd secrets versions add OPENROUTER_API_KEY --data-file=-

# 3) Habilitarlo en el archivo de ids
#    editar C:/workspace/hermes/scripts/gsm-secrets.conf y descomentar/agregar la línea

# 4) Verificar antes de reiniciar
cd C:/Users/e4dev/AppData/Local/hermes/hermes-agent
PYTHONPATH="C:/Users/e4dev/AppData/Local/hermes/hermes-agent" \
  venv/Scripts/python.exe C:/workspace/hermes/scripts/verify-gsm-source.py

# 5) Reiniciar quien deba leerla
hermes gateway restart        # gateway; el CLI la toma al relanzarse
```

### 6.2 Rotar una key

Agregar una versión nueva (`gcloud secrets versions add ...`). El plugin siempre pide
`latest`, así que el próximo arranque toma el valor nuevo; no hay que tocar nada más.

### 6.3 Verificar el estado (sin exponer valores)

```bash
cd C:/Users/e4dev/AppData/Local/hermes/hermes-agent
PYTHONPATH="C:/Users/e4dev/AppData/Local/hermes/hermes-agent" \
  venv/Scripts/python.exe C:/workspace/hermes/scripts/verify-gsm-source.py
```

Salida esperada (real, 2026-11-08):

```
sources registrados: ['gsm', 'bitwarden', 'onepassword', 'command']
[OK] gsm: applied=['DEEPSEEK_API_KEY'] skipped_existing=[]
  binario: C:\Users\e4dev\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.CMD
variables aplicadas (solo nombres): ['DEEPSEEK_API_KEY']
```

Comprobaciones de contexto:

```bash
gcloud.cmd auth list --filter=status:ACTIVE --format="value(account)"   # devopsmentor.io@gmail.com
gcloud.cmd config get-value project                                     # brave-monitor-498704-c0
gcloud.cmd secrets list --format="value(name)"                          # nombres, sin valores
```

### 6.4 ¿El gateway está corriendo, sí o sí?

`scripts/check-hermes-gateway.py` (+ wrapper `check-hermes-gateway.bat`) valida las cinco
señales que separan "proceso vivo" de "gateway sano": pidfile, proceso real (y que su línea
de comando sea la del gateway), `gateway_state.json`, estado de cada plataforma y el
`/health` del bridge local.

```bash
scripts\check-hermes-gateway.bat                 # resumen legible
scripts\check-hermes-gateway.bat --json          # para cron/scripts
scripts\check-hermes-gateway.bat --quiet         # imprime UP / DEGRADED / DOWN
scripts\check-hermes-gateway.bat pause           # igual y espera tecla (doble clic)
```

Códigos de salida: `0` = UP, `1` = DOWN, `2` = DEGRADED (avisos: bridge a medio levantar,
plataforma reconectando, heartbeat viejo). No imprime secretos.

Salida real (2026-11-09):

```
Hermes gateway — C:\Users\e4dev\AppData\Local\hermes
  [OK  ] pidfile      pid=12404 kind=hermes-gateway
  [OK  ] proceso      PID 12404 vivo · python.exe · gateway run
  [OK  ] estado       running · heartbeat hace 29s
  [OK  ] plataformas  whatsapp=connected
  [OK  ] bridge       127.0.0.1:3000 /health 200 {"status":"connected","queueLength":0,...}

Veredicto: UP · PID 12404
```

Casos que sí detecta (probados): PID muerto con pidfile presente → `DOWN` exit 1; puerto
cerrado → `DOWN`; `/health` que no responde pero puerto abierto → `DEGRADED`; plataforma en
`reconnecting` → `DEGRADED`.

### 6.5 Resurrección: levantar el gateway solo (watchdog + despertar por WhatsApp)

Como el bridge Baileys es **hijo del gateway**, si el gateway muere también muere el canal:
un mensaje de WhatsApp no puede llegar a un Hermes caído. La solución tiene dos capas:

**a) Vigilante automático (la que garantiza la resurrección).**
`scripts/hermes-wake.py` (+ `hermes-wake.bat`) revisa cada invocación si el gateway está sano
y, si no, lo arranca. Está registrado como tarea de Windows que corre **cada minuto**:

```
schtasks /Query /TN HermesGatewayWatchdog /V /FO LIST
```

| Modo | Qué hace |
|---|---|
| `--once` (default) | un chequeo; si está caído, lo levanta. Es lo que corre la tarea. |
| `--watch` | bucle residente cada `--interval` s (alternativa a la tarea) |
| `--message` | además intenta despertar "por WhatsApp" (ver b) |
| `--dry-run` | dice qué haría, sin ejecutar |
| `--install-task` / `--uninstall-task` | registra/borra la tarea `HermesGatewayWatchdog` |

Salvaguardas: **nunca** toca un gateway sano; cooldown de 120 s entre intentos (evita dobles
arranques cuando la tarea y el test coinciden); lockfile; bitácora en `cache/wake.log` y la
salida del arranque en `cache/wake-gateway-stdout.log`. El comando de arranque es
`python -m hermes_cli.main gateway run --replace` en segundo plano.

**b) Despertar por mensaje (`--message`).** Si el bridge sobrevivió al gateway, el script
levanta un bridge suelto (o usa el que quedó vivo), drena `GET /messages`, contesta en el chat
"Hermes estaba caído, lo estoy levantando" y arranca el gateway; antes de arrancar mata su
bridge para dejar libre el puerto 3000. Si el bridge murió (caso normal), esta vía no aplica:
el mensaje se pierde, pero WhatsApp **reentrega los no leídos** al reconectar y el vigilante
levanta el gateway en ≤1 minuto.

**Prueba real (2026-11-08, `cache/wake-test.log`):**

```
18:16:12  prueba de resurrección (pid antes: 12404)
18:16:18  gateway tumbado (PID 12404 ya no existe)     ← taskkill deliberado
18:16:54  gateway caído: PID 12404 muerto
18:16:54  arrancando gateway → lanzado PID 15688
18:17:06  gateway arriba: PID 16776 running            ← 12 s después
18:17:01  (la tarea horaria también disparó, pero el cooldown la frenó: "faltan 112s")
```

Estado final: `UP · PID 16776`, `whatsapp=connected`, bridge `/health` 200.

**Límites honestos:** la tarea corre como el usuario y solo con sesión iniciada (Hermes es una
app de escritorio); si el usuario cierra sesión en Windows no hay vigilante. Tampoco arregla
un gateway que esté vivo pero atascado con un canal roto: eso se ve como `DEGRADED` en
`check-hermes-gateway.py` y se resuelve con `hermes gateway restart`.

---

## 7. Problemas conocidos y cómo se diagnosticaron

| Síntoma | Causa | Diagnóstico / arreglo |
|---|---|---|
| `[FAIL] gsm: … REF_INVALID — NOT_FOUND: Secret […/DEEPSEEK_API_KEY2] not found` | el `secrets_file` listaba `DEEPSEEK_API_KEY2`, que **no existe** en GSM (el real es `DEEPSEEK_API_KEY`) | `gcloud secrets list` + el script de verificación; se corrigió el `.conf` el 2026-11-08 |
| Un id se ignora en silencio | no es nombre de variable válido (`ai-api-key` tiene guiones) | warning `ignoring invalid secret id …` en el reporte |
| El source dice `OK` pero el modelo da 401 | `providers.<p>.key_env` no coincide con el id del secreto | revisar `providers.deepseek.key_env` en `config.yaml` |
| Cambié el secreto y no pasa nada | el gateway ya arrancó: `fetch()` es solo al inicio | `hermes gateway restart` |
| `BINARY_MISSING` | `gcloud` fuera del `PATH` del proceso | instalar SDK o setear `secrets.gsm.binary_path` |
| `AUTH_EXPIRED` tras días | credenciales de usuario vencidas | `gcloud auth login` |
| Arranques lentos (~3 s por arranque) | una llamada a gcloud por secreto (en paralelo) | normal; si molesta, `cache_ttl_seconds > 0` (implica archivo `0600`) |
| Quiero ver el error crudo | el plugin resume el mensaje | correr a mano `gcloud secrets versions access latest --secret=<ID>` |

Nota histórica: en `logs/agent.log` quedó registrado el hint de remediación del plugin
(`Check secrets.gsm.secrets and secrets.gsm.project_id …`) correspondiente al `NOT_FOUND`
de arriba.

---

## 8. Estado verificado (2026-11-08)

- `hermes plugins list --plain --no-bundled` → `gsm` y `homeassistant` **enabled**.
- `verify-gsm-source.py` → `[OK] gsm: applied=['DEEPSEEK_API_KEY']`, binario `gcloud.CMD`.
- `gcloud auth list` → `devopsmentor.io@gmail.com` activa; `config get-value project` →
  `brave-monitor-498704-c0`; `secrets list` → 8 secretos (nombres en §5.4).
- Gateway: PID 16776, `platforms.whatsapp.state = connected`, bridge en `127.0.0.1:3000`.
- Tarea `HermesGatewayWatchdog`: `Last Result: 0`, corre cada minuto; prueba de resurrección
  real con gateway tumbado → `UP` en 12 s (§6.5).
- `check-hermes-gateway.py` → `Veredicto: UP · PID 16776` (5/5 checks OK).
- `cache/gsm_cache.json`: **no existe** (TTL 0 ⇒ sin caché en disco, como se espera).

## 9. Pendientes / límites

- El gateway en curso arrancó **antes** de corregir `gsm-secrets.conf`; el próximo
  `hermes gateway restart` aplica la corrección (hasta entonces sigue con lo que tenía en
  memoria).
- `secrets.gsm.project_id` está vacío a propósito: usa el proyecto activo de gcloud. Si se
  quiere fijar, poner `project_id: brave-monitor-498704-c0` para no depender del `config set`.
- No hay rotación automática ni alerta de vencimiento de credenciales de gcloud; el síntoma
  será `AUTH_EXPIRED` al arrancar.
- Los launcher scripts (`hermes-gsm.cmd|sh`) siguen existiendo para sesiones manuales; con el
  plugin activo son redundantes para el gateway y pueden quedar como respaldo.
