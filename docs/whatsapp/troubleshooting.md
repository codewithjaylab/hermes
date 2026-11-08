# Troubleshooting — WhatsApp / Hermes

Todos estos casos ya ocurrieron en esta instalación. Comandos con
`PY="$LOCALAPPDATA/hermes/hermes-agent/venv/Scripts/python.exe"` y
`H="$LOCALAPPDATA/hermes"`.

## 1. Arranque fatal: "WhatsApp enabled but not paired"

**Síntoma** — el gateway no arranca; `gateway_state.json` queda
`"gateway_state":"startup_failed"`, `"exit_reason":"whatsapp: WhatsApp enabled but not paired"`.
El CLI/chat se queda en `Gateway draining: not_ready` y nunca responde.

**Causa** — `WHATSAPP_ENABLED=true` sin `whatsapp\session\creds.json`. Hermes
0.22.1 lo trata como conflicto **no reintentable** y sale.

**Arreglo** — una de dos:

```bash
hermes whatsapp                 # emparejar (escribe ENABLED=true al terminar)

# o deshabilitar mientras tanto — edita .env (WHATSAPP_ENABLED=false),
# no con sed a ciegas: el archivo es CRLF.
hermes gateway start            # el lock viejo se reclama solo
```

## 2. `❌ Logged out` en bucle

**Síntoma** — `whatsapp\bridge.log` repite `❌ Logged out` y el bridge muere y
renace.

**Causa** — la sesión fue invalidada del lado del servidor (se desvinculó el
dispositivo, o se re-emparejó desde otro lado). El `creds.json` existe pero ya
no sirve.

**Arreglo** —

```bash
mv "$H/whatsapp/session" "$H/whatsapp/session.loggedout-$(date +%Y%m%d)"
hermes whatsapp                 # QR nuevo
hermes gateway restart
```

Respaldo existente de este caso: `whatsapp\session.loggedout-20261025`.

## 3. Hay `creds.json` pero el adapter dice que no está emparejado

**Síntoma** — `creds.json` está en `whatsapp\session\` pero el adapter busca en
otro sitio.

**Causa** — desajuste histórico de rutas: el adapter resolvía
`platforms\whatsapp\session` mientras el wizard/bridge escribían
`whatsapp\session`.

**Arreglo** — en 0.22.1 `_session_dir()` usa
`get_hermes_dir("platforms/whatsapp/session", "whatsapp/session")` (prefiere la
ruta nueva, cae a la vieja). Si aparece de nuevo, unificar: mover la sesión a
`whatsapp\session` y no dejar dos copias (el `session` reportado por `/health`
debe coincidir con el del adapter, o lo considera "bridge ajeno").

## 4. Los mensajes entrantes se ignoran (allowlist)

**Síntoma** — el bridge está `connected`, los salientes funcionan, pero tus
mensajes no generan respuesta. En `bridge.log`:
`{"event":"ignored","reason":"allowlist_mismatch",…}`.

**Causa** — formato del número. WhatsApp MX usa `52` + `1` + 10 dígitos
(`5216643297398@s.whatsapp.net`). El matcher solo recorta `+` y `@servidor`;
`6643297398` **no** coincide.

**Arreglo** — incluir la forma internacional completa (idealmente ambas):

```dotenv
WHATSAPP_ALLOWED_USERS=5216643297398,6643297398,5216862687959,526862687959,6862687959
```

Comprobar con el matcher real antes de reiniciar (versión probada):

```bash
cd "$LOCALAPPDATA/hermes/hermes-agent/scripts/whatsapp-bridge"
node --input-type=module -e "
import {readFileSync} from 'fs';
import {parseAllowedUsers, matchesAllowedSender} from './allowlist.js';
const raw = readFileSync(process.argv[1],'utf8');
const a = parseAllowedUsers(raw.match(/^WHATSAPP_ALLOWED_USERS=(.*)\$/m)[1].trim());
const s = process.argv[2];
for (const id of ['5216643297398','5216862687959','9999999999'])
  console.log(id, matchesAllowedSender(id, null, a, s));
" "C:/Users/e4dev/AppData/Local/hermes/.env" "C:/Users/e4dev/AppData/Local/hermes/whatsapp/session"
```

Salida esperada aquí: `true true false`. El matcher también resuelve LIDs vía
`lid-mapping-*` (p. ej. `58193233346797` → `true`), así que un `@lid` en la lista
funciona si su mapeo existe.

Nota: con `dm_policy=pairing` (default del adapter) un desconocido **sí** llega
al gateway, pero no recibe respuesta hasta aprobarlo (`hermes pairing
list|approve`). Con `dm_policy=allowlist` se descarta en el bridge.

## 5. Cambié el `.env` y el gateway lo ignora (bridge adoptado)

**Síntoma** — reiniciaste el gateway, `/health` sigue con el mismo `uptime`
creciente y `bridge.log` muestra la lista vieja (`Allowed users: 6643297398`).

**Causa** — al conectar, el adapter **adopta** un bridge que ya corre si
coinciden `session`, `scriptHash` y `sendReadReceipts`
(`_reuse_running_bridge`). La allowlist no entra en esa firma: no se reinyecta.

**Arreglo** — matar el Node del puerto y reiniciar:

```bash
netstat -ano -p TCP | grep ':3000' | grep LISTENING     # → PID
powershell.exe -NoProfile -Command "Get-Process -Id <PID> | Select ProcessName"
# solo si es node:
powershell.exe -NoProfile -Command "Stop-Process -Id <PID> -Force"
hermes gateway restart
grep -a "Allowed users" "$H/whatsapp/bridge.log" | tail -1
```

## 6. Puerto 3000 ocupado por otro perfil

**Síntoma** — `whatsapp_bridge_foreign_session`: "Port 3000 is already served by
a WhatsApp bridge for a different session".

**Causa** — dos perfiles de Hermes en la misma máquina; un proceso Node no puede
servir dos sesiones y Hermes se niega a matar un bridge ajeno.

**Arreglo** — dar puerto propio al perfil secundario:

```yaml
platforms:
  whatsapp:
    extra:
      bridge_port: 3001
```

Si en cambio el puerto lo tiene un proceso que no responde `/health`
(`whatsapp_bridge_unresponsive`), Hermes tampoco lo mata: hay que identificar y
detener ese proceso a mano.

## 7. `An Application Control policy has blocked this file`

**Síntoma** — ningún proceso nuevo de Hermes arranca (el gateway viejo sigue
sirviendo). `python.exe` del venv es un shim de 45 KB sin firmar.

**Causa** — WDAC / Smart App Control bloqueó el shim del venv.

**Arreglo** — usar el intérprete base firmado (intercambio de binarios + DLLs,
respaldos `*.bak-20261025-sac`), o un venv de python.org firmado, o desactivar
SAC. Mientras: invocar `python -m hermes_cli.main …` en vez de `hermes.exe`.

## 8. El gateway no ve config o secretos nuevos

**Síntoma** — `config.yaml` o `gsm-secrets.conf` corregidos en disco y el chat
sigue fallando con `No usable credentials found for provider '…'`.

**Causa** — se leen una sola vez por proceso.

**Arreglo** —

```bash
C:/workspace/hermes/scripts/hermes-gateway-reload.sh status    # 0 = stale
C:/workspace/hermes/scripts/hermes-gateway-reload.sh           # reinicia
```

## 9. Conectado pero sin mensajes: checklist rápido

1. `curl -s http://127.0.0.1:3000/health` → ¿`connected`? ¿`queueLength` crece?
2. `WHATSAPP_MODE`: en `self-chat` el bridge descarta DMs de terceros por diseño.
3. `WHATSAPP_ALLOWED_USERS` vs JID real (caso 4).
4. `dm_policy` / `group_policy` (`open|allowlist|disabled|pairing`).
5. `tail -50 "$H/whatsapp/bridge.log"` y `grep whatsapp "$H/logs/agent.log" | tail`.
6. ¿Dos bridges/gateways peleando por la sesión? `netstat -ano | grep 3000` y
   `cat "$H/whatsapp/session/bridge.pid"`.
7. Tras cada cambio: reiniciar gateway **y** asegurarse de que el bridge nació
   de nuevo (caso 5).

## Dónde mirar

- `whatsapp\bridge.log` — QR, `✅ WhatsApp connected!`, allowlist, errores del
  protocolo, `ignored` con motivo.
- `logs\agent.log` / `logs\errors.log` — adapter y gateway.
- `gateway_state.json` — `platforms.whatsapp.state`, `error_code`,
  `needs_attention`.
- `gateway.pid`, `whatsapp\session\bridge.pid` — PIDs reales.
- `hermes gateway status`, `hermes pairing list`.
