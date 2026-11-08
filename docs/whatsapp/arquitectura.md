# Arquitectura de la integración WhatsApp

## Piezas

```
 WhatsApp servers
        ▲  ▼  (protocolo WhatsApp Web / multi-device)
 ┌──────────────────────────────┐
 │ bridge Node  (bridge.js)     │  Baileys 7.0.0-rc13 + express
 │ 127.0.0.1:3000               │  mantiene la sesión, recibe y envía
 │ sesión: whatsapp\session\    │  escribe bridge.log
 └──────────────▲───────────────┘
                │ HTTP local (/messages, /send, …)
 ┌──────────────┴───────────────┐
 │ gateway Python (hermes …)    │  multiplataforma, una tarea por plataforma
 │ adapter de whatsapp          │  lanza/adopta el bridge, hace polling,
 │ agentes + toolsets           │  entrega al agente y publica respuestas
 └──────────────────────────────┘
```

- **Bridge** (`hermes-agent/scripts/whatsapp-bridge/bridge.js`): proceso Node
  independiente. Implementa el cliente de WhatsApp Web, la sesión cifrada, el
  gate de remitentes y una API HTTP local.
- **Adapter** (`plugins/platforms/whatsapp/adapter.py`): arranca el bridge con
  `node bridge.js --port <3000> --session <…>\whatsapp\session --mode <bot|self-chat>`,
  espera a que `/health` diga `connected`, hace polling de `/messages`, y expone
  `send_*` contra los endpoints del bridge.
- **Gateway**: dueño del ciclo de vida. Si una plataforma habilitada no está
  emparejada, **aborta el arranque** (`startup_failed`), no reintenta.

## Ciclo de arranque

1. Gateway lee `.env` (vía `gsm` plugin incluido) y `config.yaml` **una sola vez
   por proceso**.
2. `platforms.whatsapp.enabled: true` + `WHATSAPP_ENABLED=true` → conecta.
3. Preflight: si no existe `whatsapp\session\creds.json` → error fatal
   `whatsapp_not_paired` ("enabled but not paired").
4. Prueba `GET /health` en el puerto:
   - `status: connected` **y** mismo `scriptHash` **y** mismo `sendReadReceipts`
     **y** mismo `session` → **adopta** el bridge existente (no lo reinicia).
   - otro `session` → conflicto entre perfiles, no lo toca (fatal).
   - nada / stale → mata el proceso del puerto y lanza uno nuevo.
5. Abre `whatsapp\bridge.log` (append) y arranca `node bridge.js …`.
6. Polling de `/messages`; cada mensaje aceptado se entrega al agente y la
   respuesta vuelve por `/send` (+ `/typing`, `/read`).

## Endpoints del bridge (localhost)

- `GET /health` — estado, `uptime`, `session`, `scriptHash`, `sendReadReceipts`,
  `capabilities`.
- `GET /messages` — cola de entrantes para el polling del gateway.
- `POST /send`, `/send-media`, `/send-poll`, `/send-location`, `/edit`.
- `POST /typing`, `/read`; `GET /chat/:id`.

## Datos y configuración

`%LOCALAPPDATA%\hermes\.env` (claves relevantes; los valores aquí son los de
esta máquina):

- `WHATSAPP_ENABLED=true` — interruptor maestro. Lo escribe el wizard **solo**
  después de que `creds.json` existe.
- `WHATSAPP_MODE=bot` — `bot` (número aparte para el agente) o `self-chat`
  (te escribes a ti mismo; el bridge descarta mensajes de terceros).
- `WHATSAPP_ALLOWED_USERS=5216643297398,6643297398,5216862687959,526862687959,6862687959`
  — lista blanca de remitentes (DMs).
- `WHATSAPP_HOME_CHANNEL=58193233346797@lid` y `WHATSAPP_HOME_CHANNEL_THREAD_ID=`
  — destino por defecto para envíos proactivos/cron.
- Opcionales que el adapter reinyecta al bridge: `WHATSAPP_DM_POLICY`
  (`open|allowlist|disabled|pairing`, default del adapter: `pairing`),
  `WHATSAPP_GROUP_POLICY`, `WHATSAPP_GROUP_ALLOWED_USERS`,
  `WHATSAPP_REQUIRE_MENTION`, `WHATSAPP_MENTION_PATTERNS`,
  `WHATSAPP_FREE_RESPONSE_CHATS`, `WHATSAPP_DEBUG`,
  `WHATSAPP_REPLY_PREFIX` (default `☤ *Hermes Agent*`),
  `WHATSAPP_MAX_MESSAGE_LENGTH`, `WHATSAPP_CHUNK_DELAY_MS`,
  `WHATSAPP_SEND_TIMEOUT_MS`, `WHATSAPP_SEND_READ_RECEIPTS`.

`config.yaml`:

```yaml
platforms:
  whatsapp:
    enabled: true
    home_channel:
      platform: whatsapp
      chat_id: 58193233346797@lid
      name: J Quiroz
      user_id: 5216862687959@s.whatsapp.net
```

Además `platform_toolsets.whatsapp` define qué tools tiene el agente cuando
atiende por este canal (browser, clarify, code_execution, computer_use,
connections, cronjob, …). Una entrada inválida ahí solo genera warnings; un
`extra.bridge_port` distinto es lo que permite varios perfiles en la misma
máquina (un proceso Node no puede servir dos sesiones).

## Cómo se decide si un remitente pasa (`allowlist.js`)

1. `normalizeWhatsAppIdentifier` recorta `@s.whatsapp.net` / `@lid` y el `+`.
   **No** recorta el código de país ni el `1` mexicano.
2. Se expanden alias LID ↔ teléfono leyendo `whatsapp\session\lid-mapping-*`.
3. Hay match si algún alias del remitente está en la lista. Lista vacía =
   **nadie** pasa (default seguro); `*` = todos.
4. Política de DM: con `dm_policy=pairing` un desconocido **sí** llega al
   gateway (para emitir código de emparejamiento) pero no obtiene respuestas
   hasta aprobarlo; con `allowlist` se descarta en el bridge (`allowlist_mismatch`
   en el log del bridge). En grupos manda `group_policy`.

Consecuencia práctica: el número va en formato internacional completo
(`52` + `1` + 10 dígitos para MX). Poner solo los 10 dígitos **no** coincide con
el JID pero funciona solo si existe un `lid-mapping-<10dígitos>.json`, que en la
práctica no existe para números mexicanos.

## Envío saliente

- Respuestas: gateway → `POST /send` del bridge → WhatsApp.
- Proactivo/cron: `chat_id` del `home_channel` (`…@lid` es válido; el bridge
  resuelve el LID con los `lid-mapping-*`). `channel_directory.json` guarda el
  destino descubierto (`{"id":"58193233346797@lid","type":"dm","name":"J Quiroz"}`).
