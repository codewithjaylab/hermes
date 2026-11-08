# Procedimiento completo de conexión

Dos caminos: el wizard (recomendado, hace todo salvo la allowlist fina) o
manual (editar `.env` y emparejar a mano). Abajo, además, la bitácora real de
cómo quedó conectado en esta máquina.

## 0. Decidir el modo

- **`bot`** — un número aparte para el agente (WhatsApp Business o SIM
  secundaria). Es lo que usa esta instalación. La gente escribe a ese número.
- **`self-chat`** — usas tu número personal y te escribes a ti mismo. El bridge
  descarta DMs de terceros; más rápido de montar, UX menos clara.

Se guarda en `WHATSAPP_MODE` y se elige en el wizard.

## 1. Wizard: `hermes whatsapp`

```bash
hermes whatsapp
# si el shim .exe está bloqueado por WDAC/Smart App Control:
cd C:/Users/e4dev/AppData/Local/hermes/hermes-agent
python -m hermes_cli.main whatsapp
```

Qué hace, en orden (`hermes_cli/main_platform_setup.py`):

1. Si `WHATSAPP_MODE` está vacío, pregunta modo → lo guarda.
2. Si ya está `WHATSAPP_ENABLED=true`, lo dice.
3. Muestra/pregunta `WHATSAPP_ALLOWED_USERS` (coma-separado; `*` = cualquiera).
4. `npm install` en `scripts/whatsapp-bridge` si falta `node_modules`.
5. Si ya existe `whatsapp\session\creds.json`, ofrece **re-emparejar** (borra la
   sesión) o conservarla.
6. Lanza `node bridge.js --pair-only --session <HERMES_HOME>\whatsapp\session`
   e imprime el QR: en el teléfono → *Dispositivos vinculados* → *Vincular*.
7. Solo si `creds.json` apareció escribe `WHATSAPP_ENABLED=true` (un wizard
   abortado no deja el `.env` mintiendo) y sugiere `hermes gateway`.

## 2. Allowlist: el detalle que rompe todo

WhatsApp identifica un número mexicano como `52` + `1` + 10 dígitos:

- Tu teléfono: `+52 1 664 329 7398` → JID `5216643297398@s.whatsapp.net`.
- Poner `6643297398` en la lista **no** coincide (el matcher solo quita `+` y
  `@servidor`). Hay que meter la forma completa, y conviene la pareja:

```dotenv
WHATSAPP_ALLOWED_USERS=5216643297398,6643297398,5216862687959,526862687959,6862687959
```

- Los chats también llegan como **LID** (`58193233346797@lid`); el matcher los
  traduce con los archivos `whatsapp\session\lid-mapping-*`, así que sirve poner
  el teléfono o el LID.
- Lista vacía = nadie (default seguro). `*` = todos.

## 3. Arrancar el gateway

```bash
hermes gateway start      # o restart si ya corría
hermes gateway status
```

- El gateway lee `.env` y `config.yaml` **una vez por proceso**: cualquier
  cambio exige reinicio.
- También vale `scripts/hermes-gateway-reload.sh status` (¿config más nueva que
  el daemon?) y `… restart`.
- Ojo: al reiniciar, el adapter **puede adoptar** el bridge que ya está
  corriendo (mismo `session`, mismo `scriptHash`, mismos read-receipts) y
  entonces **no** reinyecta la allowlist nueva. Ver `troubleshooting.md` caso 5.

## 4. Verificar (no dar por hecho)

```bash
curl -s http://127.0.0.1:3000/health
# {"status":"connected","session":"…\\whatsapp\\session","scriptHash":"…",…}

grep -a "Allowed users" "$LOCALAPPDATA/hermes/whatsapp/bridge.log" | tail -1
# 🔒 Allowed users: 5216643297398, 6643297398, …

python -c "import json;d=json.load(open(r'C:/Users/e4dev/AppData/Local/hermes/gateway_state.json'));print(d['platforms']['whatsapp'])"
# {'state': 'connected', …}

tail -f "$LOCALAPPDATA/hermes/logs/agent.log" | grep whatsapp
```

Prueba final que sí vale: enviar un mensaje desde un número de la lista y ver
en `logs\agent.log` la línea `inbound message: platform=whatsapp …` seguida de
`response ready`.

## 5. Home channel y envíos proactivos

`platforms.whatsapp.home_channel.chat_id` (aquí `58193233346797@lid`) es el
destino por defecto de cron/respuestas iniciadas por el agente. Se descubre solo
y queda en `channel_directory.json`; también se puede fijar con
`WHATSAPP_HOME_CHANNEL`.

## 6. Automatizar el arranque

```bash
hermes gateway install     # Windows Scheduled Task al iniciar sesión
```

Hoy corre manual: `gateway status` lo reporta como *"Running manually, not as a
system service"*.

---

# Bitácora real

## 25 oct 2026 — se deshabilita WhatsApp

- La sesión fue invalidada del lado del servidor: el bridge moría en bucle con
  `❌ Logged out` en cada arranque. Respaldo: `whatsapp\session.loggedout-20261025`.
- Hermes 0.22.1 trata "plataforma habilitada pero no emparejada" como conflicto
  **fatal**: dos arranques con `gateway_state: startup_failed`,
  `exit_reason: whatsapp: WhatsApp enabled but not paired`, y el CLI colgado en
  `Gateway draining: not_ready`.
- Se puso `WHATSAPP_ENABLED=false` para poder usar Hermes (el gateway arranca con
  `No messaging platforms enabled`). De paso se detectó el desajuste de rutas:
  el adapter miraba `platforms\whatsapp\session\creds.json` mientras el wizard
  escribía `whatsapp\session\creds.json` (hoy resuelto: `get_hermes_dir("platforms/whatsapp/session", "whatsapp/session")`,
  con preferencia por la ruta nueva y compatibilidad con la vieja).

## 8 nov 2026 — reconexión

- **12:15** — re-escaneo del QR: sesión nueva en `whatsapp\session` (cuenta
  `+52 1 664 329 7398`, "JQuiroz", plataforma iphone, `registered: false` pero
  con credenciales válidas y `creds.json` escrito 12:29).
- **12:17** — `Connecting to whatsapp…` → `✓ whatsapp connected`. Bridge en
  `127.0.0.1:3000`, `/health` → `connected`. Ya no hay loop de logout.
- **Hallazgo** — la allowlist tenía solo `6643297398` y no había ningún mensaje
  entrante en todo el log; el JID real es `5216643297398`.
- **12:25** — backup `.env` → `.env.bak-20261108-122520`; allowlist actualizada a
  las 5 formas (dos números × ambas variantes). Verificado con el matcher real
  (`allowlist.js`), no a ojo: los 5 pasan, un número ajeno no.
- **12:26** — `gateway restart`… **inútil para la allowlist**: el gateway adoptó
  el bridge viejo (PID 13264, `uptime` sin reiniciar) y siguió con la lista
  anterior. Los envíos salientes sí funcionaban (`success:true` a ambos números).
- **12:28–12:29** — segundo intento: matar el `node` del puerto 3000 y reiniciar.
  Nuevo bridge **PID 85528**; `bridge.log` ya imprime
  `🔒 Allowed users: 5216643297398, 6643297398, 5216862687959, 526862687959, 6862687959`.
- **12:29:34** — llega `Ok` desde `5216862687959` al chat `58193233346797@lid`;
  respuesta en 4.2 s, 1 llamada a la API. **Round-trip verificado.**
- Se corrigió la nota obsoleta de `docs/telegram/knowhowto.md` que decía que
  WhatsApp estaba en estado fatal.
