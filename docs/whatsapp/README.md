# WhatsApp ↔ Hermes — proceso de conexión (esta máquina)

Documentación del emparejamiento y la conexión de WhatsApp con el gateway de
Hermes en `C:\Users\e4dev\AppData\Local\hermes`. Todo lo que sigue está
verificado contra el estado real del sistema el **8 nov 2026, 12:33**.

## TL;DR — quickstart

```bash
# 1. Emparejar (escanea el QR desde el teléfono del número del bot)
hermes whatsapp          # o: python -m hermes_cli.main whatsapp

# 2. Revisar allowlist (números en formato internacional, SIN '+')
#    MX: WhatsApp usa 52 1 <10 dígitos> → mete ambas formas
#    WHATSAPP_ALLOWED_USERS=5216643297398,6643297398

# 3. Arrancar/reiniciar el gateway
hermes gateway restart

# 4. Verificar
curl -s http://127.0.0.1:3000/health        # {"status":"connected",...}
hermes gateway status                       # ✓ Gateway is running (PID: …)
```

Si el `.env` cambió y el gateway **adoptó un bridge viejo**, la allowlist nueva
no aplica: hay que matar el proceso `node` del puerto 3000 y reiniciar
(ver `troubleshooting.md`, caso 5).

## Estado actual (verificado)

- Gateway: PID **82496**, `hermes gateway run`, versión 0.22.1, sin servicio.
- Bridge Node: PID **85528**, escuchando en `127.0.0.1:3000`.
- `/health` → `{"status":"connected","uptime":292,"scriptHash":"607a82525c938bd9","sendReadReceipts":false,"session":"…\\hermes\\whatsapp\\session"}`.
- Cuenta emparejada: **+52 1 664 329 7398** (modo `bot`).
- Allowlist: `5216643297398, 6643297398, 5216862687959, 526862687959, 6862687959`.
- Home channel: `58193233346797@lid` (LID del DM con el bot), `platforms.whatsapp.home_channel` en `config.yaml`.
- Round-trip probado: entrante `Ok` a las 12:29:34, respuesta en 4.2 s.

## Documentos

- **`arquitectura.md`** — piezas (gateway, adapter, bridge Baileys, sesión),
  puertos, endpoints, rutas en disco, variables de entorno y cómo se decide si
  un remitente pasa.
- **`procedimiento.md`** — el paso a paso completo: modos, wizard, QR,
  allowlist, arranque, verificación y automatización. Incluye la bitácora real
  del 25 oct y del 8 nov.
- **`troubleshooting.md`** — síntoma → causa → arreglo, con los fallos que ya
  ocurrieron en esta instalación (logged out, sesión en ruta equivocada,
  bridge adoptado, puerto ocupado, `python.exe` bloqueado).

## Requisitos

- Node.js ≥ 20 (aquí **v24.11.0**, npm **11.6.1**) y dependencias del bridge
  (`npm install` en `hermes-agent/scripts/whatsapp-bridge`).
- WhatsApp o WhatsApp Business instalado en un teléfono (para el QR).
- Un TTY real para el wizard (`hermes whatsapp`): es interactivo.
- Permiso para escribir en `HERMES_HOME` (`%LOCALAPPDATA%\hermes`).

## Archivos que toca la integración

```
%LOCALAPPDATA%\hermes\
├── .env                              # WHATSAPP_* (modo, allowlist, enabled, home channel)
├── config.yaml                       # platforms.whatsapp + platform_toolsets.whatsapp
├── whatsapp\
│   ├── bridge.log                    # stdout del bridge (QR, conexión, errores)
│   ├── session\                      # creds.json + claves de Baileys  ← NO borrar a la ligera
│   ├── session\bridge.pid
│   └── session.loggedout-20261025\   # respaldo de la sesión invalidada el 25 oct
├── gateway.pid / gateway_state.json  # estado del gateway (incluye platforms.whatsapp)
└── logs\agent.log, logs\errors.log   # trazas del adapter/gateway
```

Código (instalación, no editar):

```
hermes-agent\
├── plugins\platforms\whatsapp\adapter.py      # adapter Python (spawn del bridge, HTTP)
├── gateway\platforms\whatsapp_common.py       # resolución de rutas/comportamiento común
├── gateway\whatsapp_identity.py               # identidad/JID
├── scripts\whatsapp-bridge\bridge.js          # bridge Node (Baileys 7.0.0-rc13 + express)
├── scripts\whatsapp-bridge\allowlist.js       # matcher de remitentes
└── hermes_cli\main_platform_setup.py          # wizard `hermes whatsapp`
```
