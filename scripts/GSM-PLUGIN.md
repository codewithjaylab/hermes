# Google Secret Manager + Hermes — Documentación técnica

Cómo Hermes obtiene sus API keys desde **Google Secret Manager (GSM)** sin
guardarlas en disco, y por qué el mecanismo anterior (exportar variables en un
launcher) dejó de funcionar.

> **Estado:** implementado y verificado el 2026-10-24.
> **Componente nuevo:** plugin `gsm` (fuente de secretos) en
> `C:\Users\e4dev\AppData\Local\hermes\plugins\gsm\`.
> **Documentación hermana:** [`scripts/README.md`](README.md) — uso de los launchers.

---

## Índice

1. [Resumen en 30 segundos](#1-resumen-en-30-segundos)
2. [Por qué dejó de funcionar](#2-por-qué-dejó-de-funcionar)
3. [Arquitectura: antes y ahora](#3-arquitectura-antes-y-ahora)
4. [Inventario de archivos](#4-inventario-de-archivos)
5. [Cómo funciona el plugin (Python)](#5-cómo-funciona-el-plugin-python)
6. [Timing de arranque, proceso a proceso](#6-timing-de-arranque-proceso-a-proceso)
7. [Orden de resolución de credenciales en Hermes](#7-orden-de-resolución-de-credenciales-en-hermes)
8. [Configuración de referencia](#8-configuración-de-referencia)
9. [El launcher](#9-el-launcher)
10. [Modelo de seguridad](#10-modelo-de-seguridad)
11. [Operación diaria](#11-operación-diaria)
12. [Verificación](#12-verificación)
13. [Problemas frecuentes](#13-problemas-frecuentes)
14. [Limitaciones conocidas](#14-limitaciones-conocidas)
15. [Decisiones de diseño y alternativas descartadas](#15-decisiones-de-diseño-y-alternativas-descartadas)
16. [Referencias](#16-referencias)

---

## 1. Resumen en 30 segundos

- **El problema:** Hermes (v0.22.x) envía *todo* chat —incluida la consulta
  única `-z`— al **gateway en segundo plano** por WebSocket. Las API keys que el
  launcher exportaba al entorno solo llegaban al proceso CLI, que ya no habla
  con el modelo. El gateway, arrancado en otro momento y sin esas variables,
  fallaba con `No usable credentials found for provider 'deepseek'`.
- **La solución:** un **plugin de Hermes** que registra una *fuente de
  secretos* (`SecretSource`) con el hook oficial `register_secret_source`. Al
  arrancar **cada** proceso de Hermes (gateway, CLI, cron, adaptadores) baja
  los secretos de GSM con la CLI `gcloud` y los inyecta en `os.environ` — antes
  de que nadie resuelva credenciales.
- **Resultado:** ningún secreto se escribe en `.env` ni en ningún archivo; el
  launcher ya no hace llamadas a `gcloud` (arranque más rápido); y funciona
  **sin reiniciar el gateway**, incluso con el gateway que no tiene las claves
  en su entorno.
- **Una sola fuente de verdad para los nombres:** el fichero
  `scripts/gsm-secrets.conf`, que ahora lee Hermes (el plugin), no los scripts.

---

## 2. Por qué dejó de funcionar

### 2.1 Síntoma

```console
$ hermes-gsm -q "pregunta"
[hermes-gsm] Fetching secrets from Google Secret Manager...
[hermes-gsm]   OK DEEPSEEK_API_KEY loaded        ← los secretos se leían bien
[hermes-gsm] Launching Hermes...

⚠️  No usable credentials found for provider 'deepseek'. Set DEEPSEEK_API_KEY.

Your request was not processed. Send it again if you still want me to carry it out.
```

El launcher descargaba las claves correctamente, pero Hermes las rechazaba.

### 2.2 Lo que NO era

Verificado y descartado antes de tocar nada:

| Sospecha | Verificación | Resultado |
| :--- | :--- | :--- |
| Auth/proyecto de gcloud | `gcloud secrets versions access latest --secret=DEEPSEEK_API_KEY` | devolvía la clave |
| Fichero `gsm-secrets.conf` | se leen `DEEPSEEK_API_KEY` y `SUDO_PASSWORD` | OK |
| Python de Hermes ausente | `...\venv\Scripts\python.exe` existe | OK |
| `.env` opaca la variable | `HERMES_HOME/.env` tiene `# DEEPSEEK_API_KEY=` **comentado** | no interfiere |
| Prefijo de clave inválido | `resolve_api_key_provider_credentials('deepseek')` en proceso aislado | devolvía la clave (35 chars) |
| Hermes re-lanza el proceso con env saneado | `_launchers.runtime_command` solo hace `pop` de `PYTHONHOME`/`PYTHONPATH`/`VIRTUAL_ENV` | no toca API keys |

### 2.3 Causa raíz

**El chat ya no se resuelve en el proceso CLI.** Cadena exacta (con
`file:line` del código instalado en
`C:\Users\e4dev\AppData\Local\hermes\hermes-agent\`):

```
hermes_cli/main.py:3064  _run_oneshot_from_args(args)          # flag -z
    "Bypasses cli.py entirely; the transport launcher never returns."
        │
        ▼
hermes_cli/gateway_chat_startup.py:33  launch_gateway_chat(args)
        │
        ▼
hermes_cli/gateway_chat.py:288  launch_from_args(args)
    … asyncio.run(run_gateway_chat(args))                      ← WebSocket al gateway
        │
        ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  gateway (proceso daemon, pid 15616, arrancado 13:54:32)     │
   │                                                              │
   │  gateway/run_turn_prepare.py:79  _resolve_policy_agent_runtime│
   │      → runtime_provider.py:1065  resolve_runtime_provider   │
   │      → runtime_provider.py:1138  _api_key_provider_runtime  │
   │      → auth.py:2287  resolve_api_key_provider_credentials   │
   │      → auth.py:376   _resolve_api_key_provider_secret       │
   │      → config.py:2925 get_env_value_prefer_dotenv           │
   │            .env  →  (fallback) os.environ                   │
   │                                                              │
   │  ✗ DEEPSEEK_API_KEY no está en .env ni en el entorno        │
   │     de ESTE proceso                                          │
   └──────────────────────────────────────────────────────────────┘
        │
        ▼
runtime_provider.py:901
    raise AuthError("No usable credentials found for provider 'deepseek'. …")
```

Evidencia en `C:\Users\e4dev\AppData\Local\hermes\logs\errors.log`:

```
2026-10-24 16:58:33,894 WARNING gateway.run: Model resolution failed for
session agent:main:local:dm:local-…: No usable credentials found for provider 'deepseek'.
```

Fíjate en el prefijo **`gateway.run`**: el error lo emite el daemon, no la CLI.

### 2.4 Por qué exportar la variable en el launcher ya no basta

- El gateway es **daemonizado**: su proceso padre ya no existe, arrancó con su
  propio entorno y vive durante horas (aunque `hermes gateway status` diga
  *"Running manually, not as a system service"*, es decir, nadie lo relanza con
  el entorno de GSM).
- El gateway **sí conserva** las claves si se le lanza desde un shell que las
  tenga (el saneado de hijo usa `inherit_credentials=True`, así que la lista
  negra de proveedores no las quita — `tools/environments/local.py:351`), pero
  **nunca las recibe** si se lanzó desde otro sitio.
- Prueba directa de que el culpable es el proceso: un *monkeypatch* sobre
  `auth._resolve_api_key_provider_secret` **no se llegaba a ejecutar** durante
  `hermes_cli.main.main()` → la resolución ocurría en otro proceso.

### 2.5 Evidencia de la corrección

Con `DEEPSEEK_API_KEY` **eliminada del shell**:

```console
$ hermes -z "responde solo: listo"
  Google Secret Manager: applied 2 secrets      ← stderr, del plugin
Listo                                            ← respuesta real del modelo
$LASTEXITCODE = 0
```

Y en logs: el **último** `Model resolution failed` se quedó en **16:59:02**
(antes de la corrección); todas las pruebas posteriores, hasta las 17:26,
corrieron contra el **mismo gateway pid 15616**, el que no tiene las claves.

---

## 3. Arquitectura: antes y ahora

### Antes (roto)

```
tú → hermes-gsm-*.sh
        │  gcloud secrets versions access … (2 llamadas, ~5 s)
        │  export DEEPSEEK_API_KEY=…        ← SOLO en este proceso
        ▼
     hermes CLI  ──WebSocket──►  gateway daemon  ──► api.deepseek.com
                                  ✗ sin la variable → AuthError
```

### Ahora (funciona)

```
tú → hermes-gsm-git-bash-win-deepseek.sh          (sin gcloud, ~instantáneo)
        │  detecta proxy Headroom (opcional)
        ▼
     hermes CLI ─┐
                 │   ambos, al arrancar:
                 │     1. load_hermes_dotenv()            (falta el plugin aún)
                 │     2. discover_plugins()  → registra GsmSource
                 │     3. _refresh_secret_sources_after_discovery()
                 │          → gcloud (2 llamadas en paralelo, ~2,5 s)
                 │          → os.environ['DEEPSEEK_API_KEY'] = …
                 ▼
     gateway daemon  ──► api.deepseek.com   ✓ resuelve
                 ▲
                 │
     cron / adaptadores / workers  → misma secuencia en su propio proceso
```

**Clave conceptual:** Hermes ya tenía (y documenta oficialmente) un punto de
extensión para gestores de secretos externos. El plugin no inventa nada nuevo:
se limita a enchufar GSM en ese punto, que es **el mismo que usan Bitwarden y
1Password**.

---

## 4. Inventario de archivos

### Nuevos

| Ruta | Qué es |
| :--- | :--- |
| `C:\Users\e4dev\AppData\Local\hermes\plugins\gsm\plugin.yaml` | Manifiesto del plugin (`name: gsm`, `kind: standalone`, `version: 1.0.0`) |
| `C:\Users\e4dev\AppData\Local\hermes\plugins\gsm\__init__.py` | El plugin Python: clase `GsmSource` + `register(ctx)` (285 líneas) |

### Modificados

| Ruta | Cambio |
| :--- | :--- |
| `C:\Users\e4dev\AppData\Local\hermes\config.yaml` | `plugins.enabled: [gsm, homeassistant]`, `plugins.entries.gsm`, sección `secrets.gsm.*` |
| `C:\workspace\hermes\scripts\hermes-gsm-git-bash-win-deepseek.sh` | Eliminado el bucle de `gcloud` + lectura de `gsm-secrets.conf`; uso `-q` → `-z` |
| `C:\workspace\hermes\scripts\README.md` | Prerrequisitos del plugin, configuración, `-z`, alias y tarea de VS Code corregidos |
| `C:\workspace\hermes\plan-hermes-gsm-api-keys.md` | `-q` → `-z` (2 sitios) |
| `C:\workspace\hermes\scripts\GSM-PLUGIN.md` | Este documento |

### Sin tocar, y por qué

| Ruta | Motivo |
| :--- | :--- |
| `scripts/gsm-secrets.conf` | Sigue siendo **la única** lista de nombres; ahora la lee el plugin |
| `scripts/archived/*` | Copias históricas de launchers retirados; congeladas |
| `HERMES_HOME/.env` | El objetivo precisamente es **no** meter ahí claves |
| `hermes-agent\*` (el núcleo de Hermes) | Nunca se parchea: `hermes update` lo sobrescribe |

### Estado resultante en `config.yaml`

```yaml
secrets:
  bitwarden:
    enabled: false
    …
  gsm:
    enabled: true
    secrets_file: C:/workspace/hermes/scripts/gsm-secrets.conf
    cache_ttl_seconds: 0
    override_existing: true

plugins:
  enabled:
    - gsm
    - homeassistant
  disabled: []
  entries:
    gsm: { … }
```

---

## 5. Cómo funciona el plugin (Python)

### 5.1 El contrato: `SecretSource`

Todo cuelga de una clase abstracta de Hermes,
`agent/secret_sources/base.py:136`:

```python
class SecretSource(ABC):
    api_version: int = SECRET_SOURCE_API_VERSION   # = 1 hoy
    name: str = ""            # clave de la sección `secrets.<name>`; minúsculas y [a-z0-9_]
    label: str = ""           # texto que aparece en las líneas de arranque y en la procedencia
    shape: str = "mapped"     # "mapped" (VAR→ref explícita) | "bulk" (volcado implícito)
    scheme: Optional[str] = None
    override_existing_default: bool = False

    @abstractmethod
    def fetch(self, cfg: dict, home_path: Path) -> FetchResult: ...
```

Reglas del contrato (enforceadas, no sugerencias — ver
`website/docs/developer-guide/secret-source-plugin.md`):

| Regla | Consecuencia si se viola |
| :--- | :--- |
| `fetch()` **nunca lanza excepciones** | el orquestador la captura y lo reporta como `INTERNAL` |
| `fetch()` **nunca promptea** | arranca en contextos sin TTY (gateway, cron). `run_secret_cli` cierra `stdin` para que un CLI que pida datos falle rápido |
| **Síncrono y dentro del presupuesto** | el orquestador impone un techo (`secrets.<name>.timeout_seconds`, 120 s por defecto); al superarlo devuelve `TIMEOUT` y descarta el resultado |
| **Solo traes; el orquestador aplica** | nunca tocar `os.environ` a mano: te saltarías precedencia, detección de conflictos y procedencia |
| **Una traída por proceso y por `HERMES_HOME`** | guardado en `_APPLIED_HOMES` (`hermes_cli/env_loader.py`) |

Lo que **sí** decides tú: validar tus referencias, hablar con tu CLI/API, y un
`label` legible. Lo que **no**: orden, precedencia, conflictos, escritura en el
entorno.

### 5.2 Cómo se registra

Hermes declara el hook en `hermes_cli/plugins.py:1045`:

```python
("register_secret_source", "secret_source", "agent.secret_sources.registry",
 "agent.secret_sources.base:SecretSource", "secret source",
 "Register a SecretSource, run by load_hermes_dotenv() (after ~/.hermes/.env,
  before credentials are read) when secrets.<name> is enabled. …",
 {"normalize": None, "register": "register_source", "param": "source"}),
```

De ahí sale dinámicamente el método `PluginContext.register_secret_source`, que
termina en (`plugins.py:343` → `registry.py:105`):

```python
registry.register_source(source_instance, scope=<scope_key_del_manager>)
```

Puntos importantes:

- Hay que pasar una **instancia**, no la clase (`_wrong_type` hace `isinstance`).
- El registro va a la capa **scoped** por perfil (`_SCOPED_SOURCES`), y
  `list_plugin_sources()` la incluye, así que `apply_all` lo ve.
- Rechazos (nombre duplicado, `api_version` distinta, `shape` inválido…) se
  **registran como warning, nunca revientan el arranque**.

En el plugin, toda la registración es una línea:

```python
def register(ctx) -> None:
    """Plugin entry point — called by the Hermes plugin loader."""
    ctx.register_secret_source(GsmSource())
```

### 5.3 Estructura y manifiesto

```
HERMES_HOME/plugins/gsm/          # = C:\Users\e4dev\AppData\Local\hermes\plugins\gsm\
├── plugin.yaml
└── __init__.py                   # GsmSource + register(ctx)
```

```yaml
name: gsm
label: Google Secret Manager
kind: standalone
version: 1.0.0
author: local
description: >
  Google Secret Manager secret source for Hermes Agent: reads API keys at
  process startup (gateway, CLI, cron) through the local gcloud SDK's own user
  credentials, so provider keys do not have to be stored in ~/.hermes/.env.
provides_tools: []
provides_hooks: []
```

- `kind: standalone` es el valor por defecto. **No** es `platform` ni `backend`,
  así que no entra en la carga perezosa de esas categorías.
- El loader (`hermes_cli/plugins_loader.py`) importa el módulo y busca
  `register(ctx)`; si no la hay, avisa y salta el plugin.
- **Un plugin de usuario solo carga si está en `plugins.enabled`**
  (`hermes_cli/plugins_discovery.py:257 gate_manifest`). Si no:
  `not enabled in config (run 'hermes plugins enable <key>' to activate)`.

### 5.4 Recorrido por el código

Fichero: `HERMES_HOME/plugins/gsm/__init__.py` (285 líneas).

#### Imports y constantes

```python
from agent.secret_sources._cache import CachedFetch, SecretCache
from agent.secret_sources.base import (
    DEFAULT_CLI_TIMEOUT_SECONDS, ErrorKind, ErrorRules, FetchResult, SecretSource,
    classify_cli_error, coerce_float, is_valid_env_name, run_secret_cli,
)
```

Todo lo que se importa de Hermes procede de la superficie pública que la
documentación marca para plugins — `agent.secret_sources.base` está en la lista
blanca de `hermes_cli/plugin_validate_private_imports.py`. La única excepción es
`agent.secret_sources._cache` (módulo con guion bajo): es el *substrato de
caché compartido* diseñado expresamente para backends, pero aún no aparece en
esa lista, así que `hermes plugins validate` emitirá un **aviso** (nunca un
rechazo: esa comprobación es `report.warn`, no un error).

```python
_DEFAULT_CACHE_TTL = 0.0        # 0 = nada a disco (objetivo del proyecto)
_GCLOUD_ALLOW_ENV = ("APPDATA", "LOCALAPPDATA", "CLOUDSDK_CONFIG")
_PROJECT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
```

> **`_GCLOUD_ALLOW_ENV` es imprescindible en Windows.** `run_secret_cli`
> (`base.py:238`) construye el entorno del hijo con una lista mínima:
> `PATH, HOME, USERPROFILE, SYSTEMROOT, TMPDIR, TEMP, LANG, LC_ALL,
> XDG_CONFIG_HOME, XDG_DATA_HOME` — **no incluye `APPDATA`**, y justo ahí
> (`%APPDATA%\gcloud`) guarda el SDK sus credenciales de usuario. Sin pasar
> esos tres nombres, `gcloud` arrancaría sin credenciales y fallaría con
> `AUTH_FAILED` fantasma.

#### `_parse_secret_ids` / `_secret_ids` — de config a nombres

```python
def _secret_ids(cfg: dict, warnings: List[str]) -> List[str]:
    raw = cfg.get("secrets")
    ids = [str(item).strip() for item in raw if isinstance(item, str) and item.strip()] \
        if isinstance(raw, (list, tuple)) else []

    path = str(cfg.get("secrets_file") or "").strip()
    if path:
        try:
            text = Path(path).expanduser().read_text(encoding="utf-8-sig", errors="replace")
        except OSError as exc:
            warnings.append(f"cannot read secrets_file {path}: {exc}")
        else:
            ids.extend(_parse_secret_ids(text))

    unique = []
    for secret_id in ids:
        if not is_valid_env_name(secret_id):
            warnings.append(f"ignoring invalid secret id {secret_id!r} …")
        elif secret_id not in unique:
            unique.append(secret_id)
    return unique
```

- Fusiona la lista en línea (`secrets:`) con el fichero (`secrets_file:`),
  deduplicando conservando el orden.
- `utf-8-sig` tolera BOM; `splitlines()` + `strip()` tolera CRLF de Windows.
- Comentarios (`#`) y líneas en blanco se ignoran — **las mismas reglas que
  tenía el bucle del launcher**, así que `gsm-secrets.conf` no cambia de
  formato.
- **Validación con `is_valid_env_name`** (`^[A-Za-z_][A-Za-z0-9_]*$`): un id es
  a la vez el nombre del secreto en GSM y la variable de entorno que lo
  suministra. Descartar lo que no sea un nombre de variable válido es también
  una garantía de seguridad: **un id nunca puede parecer un flag** (`--flag=evil`
  se descarta con warning), así que no hace falta el separador `--` en el argv.
- Si el fichero no se puede leer, va a `warnings` (no a `error`): la fuente
  sigue viva con lo que haya en `secrets:`.

#### `_resolve_gcloud` — localizar el binario

```python
def _resolve_gcloud(cfg: dict) -> str:
    return shutil.which(str(cfg.get("binary_path") or "").strip() or "gcloud") or ""
```

Una sola llamada a `shutil.which`: en Windows respeta `PATHEXT` y devuelve
`…\google-cloud-sdk\bin\gcloud.CMD`; en POSIX, `…/bin/gcloud`. Si no está,
`binary_path` en config da el camino absoluto.

#### `_fetch_one` — la llamada a gcloud

```python
def _fetch_one(binary, secret_id, project, timeout):
    argv = [binary, "secrets", "versions", "access", "latest", f"--secret={secret_id}"]
    if project:
        argv.append(f"--project={project}")
    try:
        proc = run_secret_cli(argv, allow_env=_GCLOUD_ALLOW_ENV, timeout=timeout)
    except RuntimeError as exc:                 # spawn fallido o timeout
        return str(exc), _classify_spawn_error(str(exc))

    if proc.returncode != 0:
        message = (proc.stderr or proc.stdout or "").strip()[:300] \
            or f"gcloud exited {proc.returncode}"
        return message, classify_cli_error(message, _ERROR_RULES)

    value = (proc.stdout or "").strip()
    if not value:
        return "gcloud returned an empty value", ErrorKind.EMPTY_VALUE
    return value
```

Elecciones que importan:

| Decisión | Por qué |
| :--- | :--- |
| `run_secret_cli` en lugar de `subprocess.run` | postura auditada gratis: **argv sin shell**, entorno mínimo *allowlist* (nunca el `os.environ` completo, que a esta altura ya contiene todas las credenciales de Hermes), `NO_COLOR=1`, `stderr` sin ANSI, `stdin=DEVNULL`, y timeout convertido en `RuntimeError` limpio |
| `--secret=<id>` en **una sola pieza de argv** | el valor no puede ser interpretado como flag |
| `strip()` final | `gcloud` termina con `\n`/`\r\n`; antes el launcher hacía `value="${value%$'\r'}"` |
| `stderr[:300]` | mensaje de gcloud acotado; **contiene el nombre del secreto y el id de proyecto, nunca el valor** |
| `isinstance(outcome, str)` para distinguir éxito/fallo | el valor devuelto siempre es `str`; el fallo es tupla `(mensaje, ErrorKind)` |

#### `_ERROR_RULES` — clasificar errores

`classify_cli_error` (`base.py:85`) recorre las reglas **en orden** y devuelve
la primera cuya subcadena aparezca (en minúsculas) en el mensaje:

```python
_ERROR_RULES = (
    (ErrorKind.BINARY_MISSING, ("not recognized", "command not found", "no such file", …)),
    (ErrorKind.AUTH_EXPIRED,   ("expired", "please run: gcloud auth login", "re-authenticat", …)),
    (ErrorKind.AUTH_FAILED,    ("permission denied", "denied on resource", "forbidden", "403",
                                "401", "unauthenticated", "not authorized", "gcloud auth", "login", …)),
    (ErrorKind.NETWORK,        ("could not resolve host", "connection", "unreachable", "timed out", …)),
    (ErrorKind.REF_INVALID,    ("not found", "not_found", "does not exist", "invalid_argument", …)),
)
```

El orden **no es arbitrario**: la causa raíz (binario / credenciales) se
reporta antes que el síntoma (red / referencia), que es lo que hace que el
mensaje de arreglar sea accionable. Ejemplos reales observados en pruebas:

- secreto inexistente → `ERROR: (gcloud.secrets.versions.access) NOT_FOUND: Secret [projects/…] …` → **`REF_INVALID`**
- sin permiso → `Permission 'roles/secretmanager.versionsAccessor' denied …` → **`AUTH_FAILED`**
- sin login → `please run: gcloud auth login` → **`AUTH_EXPIRED`** (va antes que `AUTH_FAILED` a propósito)

#### `_fetch_all` — paralelismo

```python
def _fetch_all(binary, secret_ids, project, timeout):
    workers = min(8, len(secret_ids))
    with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="gsm-secret") as pool:
        for secret_id, outcome in zip(secret_ids, pool.map(
                lambda sid: _fetch_one(binary, sid, project, timeout), secret_ids)):
            …
```

**Por qué en paralelo:** medido en este host, `gcloud secrets versions access`
cuesta **2,25 / 2,42 / 2,97 s por llamada**, y el coste lo domina el arranque
del CLI de gcloud, no la red. Con 2 secretos en serie serían ~5 s (lo que hacía
el launcher); en paralelo, ~2,5 s. Tope de 8 hilos para no disparar la lista.

#### `_worst_failure` — qué error mostrar

```python
_SEVERITY = (BINARY_MISSING, AUTH_FAILED, AUTH_EXPIRED, REF_INVALID,
             NETWORK, TIMEOUT, EMPTY_VALUE, INTERNAL)
```

Si **ningún** secreto se pudo leer, se devuelve el de mayor severidad: si el
problema es que falta gcloud, no quieres que el mensaje hable de la red.

#### `GsmSource` — la clase

```python
class GsmSource(SecretSource):
    name = "gsm"
    label = "Google Secret Manager"
    shape = "mapped"
    override_existing_default = True
    remediation_hints = { ErrorKind.NOT_CONFIGURED: "…", ErrorKind.AUTH_FAILED: "…", … }
```

| Atributo | Decisión |
| :--- | :--- |
| `name = "gsm"` | clave de config `secrets.gsm` y etiqueta de procedencia `(from Google Secret Manager)` |
| `shape = "mapped"` | la lista es **explícita**: el usuario declara cada nombre de variable. `mapped` siempre precede a `bulk` en la aplican (aquí irrelevante porque Bitwarden está desactivado, pero es la semántica correcta) |
| `override_existing_default = True` | las claves de GSM **ganan** sobre `.env`/shell → una rotación en GSM surte efecto sin limpiar nada. Coincide con el default de Bitwarden/1Password |
| `remediation_hints` | anula la pista genérica (`Run 'hermes secrets gsm setup'`, que **no existe**) por instrucciones reales: `gcloud auth login`, `binary_path`, etc. Debe ser una función pura *kind → string*, sin I/O |

#### `fetch()` — el método principal

```python
def fetch(self, cfg: dict, home_path: Path) -> FetchResult:
    cfg = cfg if isinstance(cfg, dict) else {}
    result = FetchResult()

    secret_ids = _secret_ids(cfg, result.warnings)
    if not secret_ids:
        return result.fail("…no secrets are configured…", ErrorKind.NOT_CONFIGURED)

    binary = _resolve_gcloud(cfg)
    if not binary:
        return result.fail("…gcloud was not found on PATH…", ErrorKind.BINARY_MISSING)

    project = str(cfg.get("project_id") or "").strip()
    if project and not _PROJECT_RE.match(project):
        return result.fail(f"…{project!r} is not a valid GCP project id.", ErrorKind.REF_INVALID)

    ttl = coerce_float(cfg.get("cache_ttl_seconds", _DEFAULT_CACHE_TTL), …)
    cache_key = tuple([f"project={project}", *(f"secret={i}" for i in secret_ids)])
    cached = _STORE.lookup(cache_key, ttl, home_path)
    if cached is not None:                       # ← caché: sin gcloud
        result.secrets = dict(cached.secrets)
        result.binary_path = Path(binary)
        return result

    values, failures = _fetch_all(binary, secret_ids, project, timeout)

    if not values:                               # ← fallo total
        message, kind = _worst_failure(failures)
        return result.fail(f"gcloud could not read {len(failures)} configured secret(s): {message}", kind)

    result.secrets = values                      # ← éxito (parcial o total)
    result.binary_path = Path(binary)
    for secret_id, message, _kind in failures:   # ← parciales van a warnings
        result.warnings.append(f"could not read GSM secret {secret_id}: {message}")
    if not failures:                             # ← batch parcial NO se cachea
        _STORE.store(cache_key, CachedFetch(secrets=dict(values), fetched_at=time.time()),
                     ttl, home_path)
    return result
```

Orden de salidas (importa porque el orquetador hace `if not result.ok: return`
— **un `error` descarta todo el lote**):

1. `NOT_CONFIGURED` — habilitado pero sin nombres.
2. `BINARY_MISSING` — no hay `gcloud`.
3. `REF_INVALID` — `project_id` con caracteres ilegales.
4. caché fresca → valores, sin salir de Python.
5. éxito total → valores + caché.
6. **éxito parcial** → valores en `secrets` + cada fallo en `warnings`
   (**no** en `error`): el orquestador aplica lo que hay. El batch no se
   cachea para que el secreto que falta se reintente en el próximo arranque.
7. fallo total → `error` + `kind` (el de mayor severidad) + pista de arreglo.

#### Caché

```python
_STORE: SecretCache = SecretCache("gsm_cache.json", key_serializer=_cache_key_str)
```

`agent/secret_sources/_cache.py` es un doble nivel ya auditado:

- **L1 en memoria** (dict por proceso) y **L2 en disco**
  (`<HERMES_HOME>/cache/gsm_cache.json`, JSON atómico, **modo `0600`**, padre
  `0700`).
- **Ambas capas se anulan con `ttl_seconds <= 0`** — por eso
  `cache_ttl_seconds: 0` garantiza "cero claves a disco" de verdad (también
  desactiva L1, pero no importa: `_APPLIED_HOMES` ya garantiza una sola
  traída por proceso).
- La clave del caché es `project=<p>|secret=<a>|secret=<b>` (solo **nombres**,
  nunca valores).
- Cambiar `secrets.gsm.secrets` cambia la clave → el caché viejo se ignora solo.

#### `config_schema()`

Declara las claves para las superficies de setup/estados de Hermes (tabla
completa en §8). Es informativo: **no** valida ni aplica nada por sí solo.

### 5.5 Qué NO hace el plugin

- No escribe en `os.environ` (lo hace el orquestador).
- No escribe en `.env`.
- No promptea ni pide login interactivo (eso pertenece a `gcloud auth login`).
- No actualiza secretos en caliente: es un arranque por proceso.
- No toca el resto de credenciales que ya tuviera Hermes.

---

## 6. Timing de arranque, proceso a proceso

Esta sección es la que explica **por qué hace falta la re-tracción posterior al
descubrimiento de plugins** y por qué el fix funciona incluso en el gateway que
ya estaba corriendo.

### 6.1 El orden real en el gateway

```
① import-time   gateway/run.py:1586
                load_hermes_dotenv(hermes_home=…)
                    ├─ carga HERMES_HOME/.env            (override=True)
                    └─ env_loader.py:553  _apply_external_secret_sources(home)
                         → registry.apply_all(cfg, home) → escribe os.environ
                         ⚠ AÚN NO EXISTE el plugin: registry solo tiene los
                           built-ins (bitwarden/onepassword/command)
                         → report.sources vacío → EARLY RETURN en
                           env_loader.py:693 → _APPLIED_HOMES NO se marca
                           (sigue reintentable, a propósito)

② startup       gateway/run_startup.py:1071   discover_plugins()
                    → PluginManager.discover_and_load()        (plugins.py:1277)
                        → importa plugins/gsm/__init__.py
                        → register(ctx) → registry.register_source(GsmSource())

③ post-discovery plugins.py:1315-1318  _refresh_secret_sources_after_discovery()
                    → env_loader.reset_secret_source_cache(home)
                          (limpia _APPLIED_HOMES)
                    → load_hermes_dotenv(home) otra vez
                    → ahora sí: apply_all → gcloud → os.environ['DEEPSEEK_API_KEY']

④ adapters      run_startup.py (conexión de plataformas) — ya con credenciales

⑤ por turno     gateway/run_turn_prepare.py:79 → resolve_runtime_provider
                    → auth.py lee .env (no está) → fallback os.environ ✓
```

Los cuatro pasos ②-④ ocurren **antes** de que nadie resuelva credenciales para
una petición, porque la resolución es *per-turn*.

### 6.2 ¿Por qué el gateway que ya estaba corriendo funciona sin reinicio?

Porque **recarga los plugins en caliente**. Al ejecutar
`hermes plugins enable gsm` la salida fue:

```console
✓ Plugin gsm enabled. Takes effect on next session.
Gateway reloaded plugins; nothing of this plugin needs a session or restart.
  Google Secret Manager: applied 2 secrets
```

Ese reload pasa por `gateway/run_plugin_rewire.py:109`
(`discover_plugins(force=True)`), que vuelve a ejecutar ② y ③ dentro del
proceso vivo. De hecho, la prueba final se hizo contra el **mismo pid 15616**
sin reiniciarlo.

### 6.3 Por proceso

| Proceso | ¿Descubre plugins? | ¿Recibe las claves? |
| :--- | :--- | :--- |
| CLI de chat / `-z` | Sí — `main.py:2903 _prepare_agent_startup` (`_AGENT_COMMANDS = {None, "chat", "acp", "rl"}`, `main.py:2852`) | Sí |
| Gateway (daemon) | Sí — `run_startup.py:1071` | Sí |
| Cron (disparo externo) | Sí — `cron/scheduler.py` hace `discover_plugins()` + re-hydratación por disparo | Sí (cuesta ~2,5 s por disparo) |
| Workers seguros / safe mode | **No** (`plugins.py:1282`: `if safe_worker_enabled() or plugin_discovery_suppressed()`) | No — deliberado |
| `hermes update` | No — nunca resuelve fuentes externas (evita arrastrar libs opcionales al proceso que reemplaza el entorno) | No (no hace falta) |
| `hermes doctor` y otros introspectivos | **No** — `main.py:2921` hace `return` si el comando no está en `_AGENT_COMMANDS` | No → **falso negativo, ver §14.1** |

---

## 7. Orden de resolución de credenciales en Hermes

El plugin basta porque se engancha justo en el punto que Hermes lee. Cadena
completa para un proveedor de API key (`hermes_cli/auth.py:376`):

```python
def _resolve_api_key_provider_secret(provider_id, pconfig):
    # 0. copilot → token propio (intercambio OAuth), caso especial
    # 1. model.key_env / model.api_key_env   — solo si config.model.provider coincide
    #    (la UI de Desktop guarda ahí el puntero en vez de la variable canónica)
    for env_var in pconfig.api_key_env_vars:          # deepseek → ("DEEPSEEK_API_KEY",)
        val = _usable_declared_secret(provider_id,
                get_env_value_prefer_dotenv(env_var), env_var)
        if val:
            return val, env_var
    # 2. credential pool (auth.json: entries con source "env:DEEPSEEK_API_KEY", …)
    # 3. return "", ""
```

Candidato:

- `_usable_declared_secret` (`auth.py:339`): `has_usable_secret` (≥4 chars) +
  **prefijo declarado** (`KNOWN_PROVIDER_KEY_PREFIXES`). Si no encaja, **avisa y
  sigue buscando** en vez de devolver la clave mala.
- `get_env_value_prefer_dotenv` (`config.py:2925`):

  ```python
  raw = load_env().get(key) or ""          # HERMES_HOME/.env
  if raw.startswith("op://"):              # referencia 1Password sin resolver
      … scope activo …
  return raw or _scoped_environ_get(key)   # ← fallback: os.environ
  ```

En este host `.env` **no** define `DEEPSEEK_API_KEY` (línea comentada), así que
siempre se llega al fallback `os.environ` — que es exactamente donde escribe el
plugin. **No hay que competir con `.env`.**

Si todo falla, `runtime_provider.py:901` lanza el `AuthError` que vimos:

```python
raise AuthError(f"No usable credentials found for provider '{provider}'.{hint}",
                provider=provider, code="missing_api_key")
```

---

## 8. Configuración de referencia

### 8.1 `secrets.gsm` (en `HERMES_HOME/config.yaml`)

| Clave | Tipo | Default | Descripción |
| :--- | :--- | :--- | :--- |
| `enabled` | bool | `false` | Interruptor maestro. `false` → ni se invoca `gcloud` |
| `secrets_file` | string | `''` | Ruta a un fichero con un id por línea (`#` comentarios). **Es lo que apunta a `scripts/gsm-secrets.conf`** |
| `secrets` | lista | `[]` | Ids en línea, **se fusionan** con `secrets_file` (deduplicados) |
| `project_id` | string | `''` | Proyecto GCP. Vacío → `gcloud` usa su proyecto activo (`gcloud config get-value project`) |
| `binary_path` | string | `''` | Ruta absoluta a `gcloud`. Vacío → `PATH` (vía `shutil.which`, que resuelve `gcloud.CMD` en Windows) |
| `cache_ttl_seconds` | num | `0` | `0` = **nada a disco** y sin caché. `300` = evita la ronda de ~2,5 s; escribe `<HERMES_HOME>/cache/gsm_cache.json` con `0600` durante 5 min |
| `cli_timeout_seconds` | num | `30` | Techo por llamada a `gcloud` (`DEFAULT_CLI_TIMEOUT_SECONDS`) |
| `timeout_seconds` | num | `120` | Techo del **orquestador** sobre `fetch()` entero (`secrets.<name>.timeout_seconds`) |
| `override_existing` | bool | `true` | Los valores de GSM pisan los de `.env`/shell (necesario para que una rotación surta efecto) |

Otros debajo de `secrets:` (globales, no específicos de gsm):

- `secrets.sources: [gsm, …]` — orden explícito de aplicación (los `mapped`
  mandan sobre los `bulk` pase lo que pase).
- `secrets.preserve_existing: [VAR, …]` — esas variables **jamás** se pisan,
  ni siquiera con `override_existing: true`.
- `secrets.profile_alias` — alias `FOO_<PERFIL>` → `FOO` (default `true`).

**Cómo se cambia (usar siempre el CLI, no editar a mano — hay candado y
escritura atómica):**

```powershell
$py = "C:\Users\e4dev\AppData\Local\hermes\hermes-agent\venv\Scripts\python.exe"

& $py -m hermes_cli.main config set secrets.gsm.enabled true
& $py -m hermes_cli.main config set secrets.gsm.secrets_file "C:/workspace/hermes/scripts/gsm-secrets.conf"
& $py -m hermes_cli.main config set secrets.gsm.cache_ttl_seconds 0
& $py -m hermes_cli.main config get secrets.gsm.enabled        # → true
```

### 8.2 Habilitar el plugin (requisito)

Un plugin de usuario **no carga** si no está en `plugins.enabled`
(`plugins_discovery.py:299`):

```powershell
& $py -m hermes_cli.main plugins enable gsm --no-allow-tool-override
```

Eso escribe `plugins.enabled: [gsm, …]` y un registro en `plugins.entries.gsm`.
Verificación:

```powershell
& $py -m hermes_cli.main plugins list | Select-String gsm
#  │ gsm │ enabled │ 1.0.0 │ Google Secret Manager secret │ user │
```

`--no-allow-tool-override` es correcto aquí: el plugin no toca herramientas
built-in; sin esa flag, el comando pediría confirmación interactiva.

### 8.3 `scripts/gsm-secrets.conf`

Formato **idéntico al de antes** (por eso no hizo falta migrar nada):

```
# ── API Keys from Google Secret Manager ──
# Líneas que empiezan por # y líneas en blanco se ignoran (CRLF admitido)
DEEPSEEK_API_KEY
SUDO_PASSWORD
#OPENROUTER_API_KEY
```

Reglas efectivas (aplicadas por `_secret_ids`):

- Una entrada por línea.
- Debe ser **a la vez** un id de secreto en GSM **y** un nombre de variable de
  entorno legal (`^[A-Za-z_][A-Za-z0-9_]*$`). No vale `FOO=BAR` ni `--flag`.
- La variable resultante se llama **exactamente igual** que el secreto.

---

## 9. El launcher

`scripts/hermes-gsm-git-bash-win-deepseek.sh` quedó **deliberadamente fino**:

```bash
set -euo pipefail
PYTHON_EXE="/c/Users/e4dev/AppData/Local/hermes/hermes-agent/venv/Scripts/python.exe"

[[ -f "$PYTHON_EXE" ]] || { echo "[hermes-gsm] ERROR: ..."; exit 1; }

# ¿Proxy Headroom en 8787? → ahorra tokens reenviando las llamadas
if netstat -ano 2>/dev/null | grep -q "8787"; then
    export DEEPSEEK_BASE_URL="http://localhost:8787/v1"
    export GEMINI_BASE_URL="http://localhost:8787/v1beta"
fi

exec "$PYTHON_EXE" -m hermes_cli.main "$@"
```

**Lo que se quitó y por qué:**

| Eliminado | Motivo |
| :--- | :--- |
| Lectura de `gsm-secrets.conf` + validación + `trim` | ahora la hace el plugin en Python |
| El bucle `gcloud secrets versions access …` + `export` | redundante: cuesta ~5 s por arranque y, sobre todo, **ya no llegaba al proceso que lo necesitaba** (el gateway) |
| `SCRIPT_DIR` / `CONFIG_FILE` / `SECRETS=()` | sin uso |

**Lo que se conserva:**

- La ruta al Python de la venv — Hermes se lanza con
  `python -m hermes_cli.main`, **no** con `hermes.exe`, porque en este host
  `hermes.exe` está bloqueado por Device Guard/WDAC (commit `7b372f6`).
- El detalle del proxy Headroom (es configuración de *endpoint*, no secreto, y
  sigue necesitando la env en **este** proceso, que es quien redirige).
- `exec` → el CLI de Hermes sustituye al shell (mismo pid, señales directas).

**Uso** (corregido: el flag de consulta única en el nivel superior es `-z`;
`-q` solo existe bajo el subcomando `hermes chat`):

```bash
./hermes-gsm-git-bash-win-deepseek.sh                  # chat interactivo
./hermes-gsm-git-bash-win-deepseek.sh -z "pregunta"    # consulta única
./hermes-gsm-git-bash-win-deepseek.sh --resume id      # reanudar sesión
```

---

## 10. Modelo de seguridad

| Riesgo | Cómo lo cubre esta implementación |
| :--- | :--- |
| Claves en disco | `cache_ttl_seconds: 0` → `SecretCache` anula L1 **y** L2. Verificado: no existe `<HERMES_HOME>/cache/gsm_cache.json` |
| Claves en `.env` | nunca se escribe; `.env` sigue con la plantilla comentada |
| Fuga al hijo de gcloud | `run_secret_cli` = entorno *allowlist* mínimo (no el `os.environ` completo), `stdin=DEVNULL`, `NO_COLOR`, sin shell. Solo se añaden `APPDATA`/`LOCALAPPDATA`/`CLOUDSDK_CONFIG`, que son la ruta de credenciales de gcloud |
| Inyección de argv | ids validados con `is_valid_env_name` → nunca empiezan por `-`; van como `--secret=<id>` en una sola pieza |
| Prompt en arranque | `stdin` cerrado: un CLI que pida datos falla rápido (`ErrorKind`) en vez de bloquear el gateway |
| `gcloud` colgado | `cli_timeout_seconds` (30 s) por llamada + `timeout_seconds` del orquestador (120 s) sobre `fetch()` |
| Secretos en mensajes de error | solo se trunca `stderr[:300]` de gcloud, que contiene **nombres** de secreto/proyecto, nunca el valor; la caché no se serializa en logs |
| Procedencia visible | el orquestador imprime `  Google Secret Manager: applied 2 secrets` y etiqueta cada variable con su fuente |
| Confianza | Hermes lo dice explícitamente: *"the trust boundary remains 'enabled plugins run with agent privilege'"* — un plugin habilitado corre con privilegio de agente. Habilitar solo lo que conoces (`plugins.enabled` es la compuerta) |
| Rotación | `override_existing: true` → el valor fresco de GSM pisa al viejo sin tocar nada más; `secrets.preserve_existing` sigue pudiendo proteger nombres concretos |

**Qué queda en memoria:** los valores viven en `os.environ` de cada proceso
Hermes mientras viva. Es inevitable — hay que mandarlos al modelo — y es el
mismo coste que tenían los launchers.

---

## 11. Operación diaria

### Añadir una API key

1. Crear el secreto en GSM con el **mismo nombre** que la variable:
   ```bash
   printf '%s' 'sk-…' | gcloud secrets create MI_API_KEY --data-file=-
   ```
   (o añadir una versión: `gcloud secrets versions add MI_API_KEY --data-file=-`)
2. Añadir `MI_API_KEY` a una línea de `scripts/gsm-secrets.conf`.
3. Asegurar permiso: la cuenta necesita `roles/secretmanager.secretAccessor`
   sobre el secreto.
4. Reiniciar lo que lo vaya a usar — el plugin lee una vez por proceso:
   `hermes gateway restart` si lo usa el gateway, o basta con relanzar Hermes.

### Rotar una clave

1. `gcloud secrets versions add <id> --data-file=-` (la `latest` pasa a ser la nueva).
2. Con `override_existing: true` basta con reiniciar el proceso que la use; no
   hay que limpiar `.env` ni nada.
3. Si `cache_ttl_seconds > 0`, el cambio tarda hasta TTL en verse → o baja el
   TTL, o `hermes gateway restart`.

### Quitar una clave

1. Borrar la línea de `gsm-secrets.conf`.
2. Al arrancar, `enabled_source_names` ya no la incluye →
   `_revoke_secret_source_writes` (`env_loader.py:684`) **revoca** el valor que
   la fuente hubiera escrito antes. No queda como residuo en `os.environ`.

### Desactivar todo

```powershell
& $py -m hermes_cli.main config set secrets.gsm.enabled false   # la fuente no se invoca
& $py -m hermes_cli.main plugins disable gsm                     # ni siquiera se registra
```

Si `secrets.gsm.enabled` pasa a `false` pero había escrituras previas, el
orquestador las revoca en el siguiente arranque (mismo mecanismo).

### Recargar plugins sin reiniciar el gateway

`hermes plugins enable …` / `hermes plugins disable …` dispara la recarga en
el gateway vivo (`gateway/run_plugin_rewire.py:109 → discover_plugins(force=True)`).
Para cualquier otro cambio de config que quieras aplicar al daemon:
`hermes gateway restart` (breve desconexión de WhatsApp/cron).

---

## 12. Verificación

Comandos copiables. Los de ① a ⑤ van en **PowerShell**; el de ⑥ va en
**Git Bash** (se indica en su sitio).

```powershell
$py   = "C:\Users\e4dev\AppData\Local\hermes\hermes-agent\venv\Scripts\python.exe"
$bash = "C:\Program Files\Git\bin\bash.exe"
```

**① Sintaxis del launcher**

```powershell
& $bash -n C:/workspace/hermes/scripts/hermes-gsm-git-bash-win-deepseek.sh   # sin salida = OK
```

**② Estado del plugin y de la config**

```powershell
& $py -m hermes_cli.main plugins list | Select-String gsm   # → … │ enabled │ 1.0.0 │ … │ user │
& $py -m hermes_cli.main config get secrets.gsm.enabled      # → true
& $py -m hermes_cli.main config get secrets.gsm.secrets_file # → C:/workspace/hermes/scripts/gsm-secrets.conf
& $py -m hermes_cli.main config get secrets.gsm.cache_ttl_seconds  # → 0
```

**③ La prueba que importa: funcionar SIN variables en el entorno**

```powershell
Remove-Item Env:\DEEPSEEK_API_KEY   -ErrorAction SilentlyContinue
Remove-Item Env:\SUDO_PASSWORD      -ErrorAction SilentlyContinue

& $bash C:/workspace/hermes/scripts/hermes-gsm-git-bash-win-deepseek.sh -z "responde solo: hola"
```

Esperado: en **stderr** `  Google Secret Manager: applied 2 secrets`, en
**stdout** la respuesta del modelo, y `$LASTEXITCODE = 0`.

**④ Que el gateway no vuelva a fallar**

```powershell
Select-String -Path "$env:LOCALAPPDATA\hermes\logs\errors.log" `
              -Pattern "Model resolution failed" | Select-Object -Last 1
```

Esperado: la última coincidencia **no debe tener fecha posterior** a la
corrección. (Si hay una nueva, mira la hora y el `kind` del mensaje.)

**⑤ La fuente aislada, sin arrancar Hermes**

```powershell
& $py -c "import sys; sys.path.insert(0, r'C:\Users\e4dev\AppData\Local\hermes\hermes-agent'); import importlib.util as u; s=u.spec_from_file_location('g', r'C:\Users\e4dev\AppData\Local\hermes\plugins\gsm\__init__.py'); m=u.module_from_spec(s); s.loader.exec_module(m); r=m.GsmSource().fetch({'enabled':True,'secrets_file':r'C:\workspace\hermes\scripts\gsm-secrets.conf'}, __import__('pathlib').Path(r'C:\Users\e4dev\AppData\Local\hermes')); print('ok=', r.ok, 'kind=', r.error_kind, 'n=', len(r.secrets), 'w=', r.warnings)"
```

Esperado: `ok= True kind= None n= 2 w= []`.

**⑥ Explicar el falso negativo de `doctor` (opcional)** — pega esto en una
terminal de **Git Bash** (no en PowerShell: aquí el multilinea entre comillas
simples es lo que hace que funcione):

```bash
"/c/Users/e4dev/AppData/Local/hermes/hermes-agent/venv/Scripts/python.exe" -c '
import sys
sys.path.insert(0, r"C:\Users\e4dev\AppData\Local\hermes\hermes-agent")
from hermes_cli.doctor_config import _provider_has_credentials
print("before discovery:", _provider_has_credentials("deepseek"))
from hermes_cli.plugins import discover_plugins
discover_plugins()
print("after discovery :", _provider_has_credentials("deepseek"))
'
```

Esperado: `before discovery: False` / `after discovery: True` (ver §14.1).

**⑦ Validación del plugin (la revisión de calidad de Hermes)**

```powershell
& $py -m hermes_cli.main plugins validate "C:\Users\e4dev\AppData\Local\hermes\plugins\gsm"
Write-Host "exit: $LASTEXITCODE"
```

Esperado: **`Validation passed.`** y `exit: 0`, con todos los checks en ✓ más
**un único ⚠** por los imports privados de `agent.secret_sources._cache` — es
el aviso documentado en §14.4, no un fallo. Entre los ✓ están `manifest`,
`loadable`, `capability probe — register() ran in isolation` (ejecuta
`register()` de verdad) y `security scan — safe`.

---

## 13. Problemas frecuentes

| Síntoma | Causa | Arreglo |
| :--- | :--- | :--- |
| `No usable credentials found for provider 'deepseek'. Set DEEPSEEK_API_KEY.` en consola **y** en `logs/errors.log` con prefijo `gateway.run` | el proceso (normalmente el gateway) no tiene el plugin activo o `secrets.gsm` desactivado | `plugins list` → `gsm enabled`; `config get secrets.gsm.enabled` → `true`; `hermes plugins enable gsm` recarga el gateway en caliente |
| `Skipping 'gsm' (not in plugins.enabled)` en logs | plugin creado pero no habilitado | `hermes plugins enable gsm` |
| `secrets.gsm.enabled is true but no secrets are configured` (`NOT_CONFIGURED`) | `secrets_file` vacío o erróneo y `secrets: []` | `hermes config set secrets.gsm.secrets_file C:/workspace/…/gsm-secrets.conf` |
| `cannot read secrets_file …` (warning) | ruta inexistente o sin permisos | corregir la ruta; se fusiona con `secrets:`, no la sustituye |
| `ignoring invalid secret id '…'` (warning) | el id no es nombre de variable válido (`FOO=BAR`, `--flag`, espacios) | renombrar el secreto a `[A-Za-z_][A-Za-z0-9_]*` |
| `gcloud was not found on PATH …` (`BINARY_MISSING`) | SDK no instalado o no en el PATH de **ese** proceso | instalar el SDK o `config set secrets.gsm.binary_path <ruta>\gcloud.cmd` |
| `Permission … denied` / `unauthenticated` (`AUTH_FAILED`) | sin rol o sin login | `gcloud secrets versions add …` con el rol `secretmanager.secretAccessor`; `gcloud auth login` |
| `please run: gcloud auth login` (`AUTH_EXPIRED`) | credenciales caducadas | `gcloud auth login` |
| `NOT_FOUND: Secret […] does not exist` (`REF_INVALID`) | id o proyecto equivocado | revisar `gsm-secrets.conf` y `secrets.gsm.project_id` |
| `fetch exceeded 120s budget` (`TIMEOUT`) | lote grande o gcloud muy lento | subir `secrets.gsm.timeout_seconds` (orquestador) y/o `cli_timeout_seconds` |
| Aparece en el **arranque** y Hermes sigue sin claves | `secrets.gsm` correcto pero el plugin no llegó a registrarse | mirar si el proceso es *safe worker* / `HERMES_SAFE_MODE=1` (§6.3) |
| `hermes doctor` marca `✗ no API key` | falso negativo, §14.1 | ignorar, o confirmar con §12⑥ |
| `'…' is not a `hermes` command` al usar `-q` | `-q` es del subcomando `chat`, no del nivel superior | usar `-z "pregunta"` |
| `No such file or directory` al invocar el launcher desde PowerShell | `bash` en el PATH es **WSL**, no Git Bash | usar `& "C:\Program Files\Git\bin\bash.exe" <script>` (así está en README) |
| Algunos procesos tardan ~2,5 s más | `cache_ttl_seconds: 0` (intencionado) | `hermes config set secrets.gsm.cache_ttl_seconds 300` si aceptas el caché `0600` de 5 min |

---

## 14. Limitaciones conocidas

### 14.1 `hermes doctor` miente: `✗ model.provider 'deepseek' is set but no API key is configured`

No es un bug de esta instalación, es un **falso negativo estructural** para
cualquier fuente externa (Bitwarden/1Password lo verían igual):

- `hermes_cli/main.py:2852` → `_AGENT_COMMANDS = {None, "chat", "acp", "rl"}`.
- `hermes_cli/main.py:2921` → `if not (args.command in _AGENT_COMMANDS …): return`
  en `_prepare_agent_startup`.
- `doctor` no está en el conjunto → **nunca descubre plugins** → `GsmSource`
  no se registra → `os.environ` sin la clave.
- `doctor_config.py:301` → `_provider_has_credentials('deepseek')` = `False`.

Medido: `False` antes de `discover_plugins()`, `True` después. La sugerencia
del mensaje ("añádela a `.env`") es justamente lo que este proyecto descartó.
Arreglarlo exige tocar el núcleo de Hermes, que `hermes update` sobrescribe.

**Comandos que sí mienten bien:** `hermes -z`, `hermes chat`, `hermes status`.

### 14.2 Coste por proceso

Una ronda de `gcloud` (~2,5 s con 2 secretos, en paralelo) **por proceso** que
descubra plugins. El gateway la paga una vez; cron la paga **en cada disparo**;
cada CLI nuevo la paga al arrancar. Sube `cache_ttl_seconds` si duele.

### 14.3 Procesos sin descubrimiento no reciben nada

*Safe workers*, `HERMES_SAFE_MODE=1` y `hermes update` no resuelven fuentes
externas (por diseño: aislamiento y velocidad). Si algún flujo crítico pasa por
ahí y necesita claves, hay que dárselas por otra vía.

### 14.4 Aviso de `private core imports` (confirmado, inofensivo)

`hermes plugins validate` sobre este plugin sale **`Validation passed.` con
exit 0**, y además emite exactamente este aviso:

```
⚠ private core imports (catalog rule 9: public surfaces only; these can break on any release):
  __init__.py:37 agent.secret_sources._cache.CachedFetch;
  __init__.py:37 agent.secret_sources._cache.SecretCache.
  Use ctx.* / documented plugin APIs, or open an issue for the seam you need.
```

`agent.secret_sources._cache` no está en la lista blanca de
`hermes_cli/plugin_validate_private_imports.py`. La comprobación es
`report.warn`, **nunca un rechazo**. Se evitaría reimplementando la escritura
JSON atómica `0600` — no merece la pena duplicar código auditado, y la guía
oficial apunta a `_cache` como "shared cache substrate for external
secret-source backends".

### 14.5 El gateway se recarga, pero no adivina

Los cambios de `config.yaml`/`gsm-secrets.conf` se leen una vez por proceso.
Para el daemon vivo: `hermes plugins enable/disable` (recarga en caliente) o
`hermes gateway restart`.

### 14.6 Fuente única de nombres = intencionada

`gsm-secrets.conf` es ahora la entrada de **Hermes** (vía `secrets_file`), no de
los scripts. Si algún día se retira ese fichero, hay que mover los nombres a
`secrets.gsm.secrets` en `config.yaml`.

---

## 15. Decisiones de diseño y alternativas descartadas

| Decisión | Alternativas descartadas y por qué |
| :--- | :--- |
| **Plugin `SecretSource`** (la elegida) | Es el punto de extensión oficial de Hermes, ya lo usan Bitwarden/1Password, llega a **todos** los procesos y no persiste nada. Coste: ~2,5 s por proceso y hay que mantener el plugin |
| **Reiniciar el gateway desde el launcher** con un sello de PID | Claves solo en memoria, sin tocar el script mucho. Descartada: solo funciona si el launcher es la única puerta de entrada — cualquier otro arranque (otra terminal, tarea de VS Code, reboot) vuelve a dejar el daemon sin claves |
| **Escribir las claves en `HERMES_HOME/.env`** | Solución más simple y que Hermes lee directamente. Descartada: pone los secretos en disco, que es exactamente lo que motivó usar GSM |
| **CLI `gcloud`** en vez de `google-cloud-secretmanager` (Python) | La lib **no está instalada** en la venv de Hermes, y ese venv lo gestiona y repara Hermes (`venv_sync` / `check_runtime`) — instalarla a mano pelea con él. Además, el flujo existente ya usaba `gcloud` con credenciales de usuario, no ADC |
| **`shape = "mapped"`** | La lista es explícita (el usuario declara cada nombre). `bulk` describiría un volcado implícito de un proyecto entero. Consecuencia práctica nula hoy (Bitwarden desactivado), pero es la semántica correcta y gana precedencia |
| **`cache_ttl_seconds = 0` por defecto** | Hermes por defecto usa `300` en Bitwarden/1Password. Aquí mandó el objetivo "cero claves en disco"; el coste (~2,5 s/proceso) es menor que el que ya pagaba el launcher (5 s) |
| **Quitar el bucle `gcloud` del launcher** | Mantenerlo habría dado redundancia (CLI sin plugin seguiría funcionando), pero costaría ~5 s extra por arranque — y **de todos modos no arreglaba el gateway**, que es donde estaba el fallo |
| **Fuentes en paralelo** | En serie, 2 secretos = ~5 s. El coste lo domina el arranque de gcloud, no la red, así que paralelizar es ganancia casi libre |
| **No parchear `hermes-agent\*`** | Todo cambio en el núcleo desaparece con `hermes update`; además afectaría a todos los perfiles y flujos |

---

## 16. Referencias

### En este repo

- [`scripts/README.md`](README.md) — uso de los launchers, alias, tarea de VS Code
- `scripts/gsm-secrets.conf` — lista de nombres de secretos
- `scripts/hermes-gsm-git-bash-win-deepseek.sh` — launcher activo
- `plan-hermes-gsm-api-keys.md` — plan original del flujo GSM
- `scripts/archived/` — launchers antiguos (congelados)

### En la instalación de Hermes (`C:\Users\e4dev\AppData\Local\hermes\`)

- `plugins/gsm/plugin.yaml`, `plugins/gsm/__init__.py` — el plugin
- `config.yaml` — `plugins.enabled`, `secrets.gsm.*`
- `cache/` — donde **no** debe haber `gsm_cache.json` con `ttl=0`
- `logs/errors.log`, `logs/gateway.log` — evidencia de resolución de credenciales
- `gateway_state.json` — pid/estado del daemon

### En el código de Hermes (`...\hermes-agent\`)

| Qué | Dónde |
| :--- | :--- |
| Hook de registro | `hermes_cli/plugins.py:1045`, `:343`, `:1070` |
| Recarga tras descubrir | `hermes_cli/plugins.py:1315-1318`, `:1341` |
| Gate de habilitación | `hermes_cli/plugins_discovery.py:257` |
| ABC + helpers | `agent/secret_sources/base.py` (`SecretSource:136`, `classify_cli_error:85`, `run_secret_cli:238`) |
| Orquestador | `agent/secret_sources/registry.py` (`register_source:105`, `apply_all:381`) |
| Caché | `agent/secret_sources/_cache.py` |
| Aplicación al entorno | `hermes_cli/env_loader.py` (`load_hermes_dotenv:458`, `_apply_external_secret_sources:642`) |
| Resolución de credenciales | `hermes_cli/auth.py:376`, `:2287`; `hermes_cli/config.py:2925` |
| Delegación al gateway | `hermes_cli/main.py:3064` → `gateway_chat_startup.py:33` → `gateway_chat.py:288` |
| Falso negativo de doctor | `hermes_cli/main.py:2852`, `:2921`; `doctor_config.py:237`, `:301` |

### Documentación upstream

- Guía oficial de fuentes de secretos:
  `hermes-agent/website/docs/developer-guide/secret-source-plugin.md`
  (contrato, timing, kit de conformidad `tests/secret_sources/conformance.py`,
  tabla de `ErrorKind`)
- Introducción a plugins: `hermes-agent/website/docs/user-guide/features/plugins.md`
- Secretos de usuario: `hermes-agent/website/docs/user-guide/secrets/index.md`
- Google Secret Manager (acceso por versión):
  <https://cloud.google.com/secret-manager/docs/access-secret-version>

