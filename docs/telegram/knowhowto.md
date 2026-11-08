

1) En Telegram, abre @BotFather → /newbot → nombre → username terminando en _bot. Te devuelve un token tipo 8123456789:AAH....

2) Guarda el token (yo lo puedo hacer si me lo pasas, o hazlo tú):

   Edita C:\Users\e4dev\AppData\Local\hermes\.env y pon:


   TELEGRAM_BOT_TOKEN=tu_token_aqui
   TELEGRAM_ALLOWED_USERS=tu_user_id


   Alternativa interactiva: hermes gateway setup → Telegram.

3) Reinicia el gateway para que tome el token:


   hermes gateway restart


   Si el shim falla por WDAC: cd C:/Users/e4dev/AppData/Local/hermes/hermes-agent && python -m hermes_cli.main gateway restart

4) Escríbele al bot en Telegram. Si no te responde, autoriza tu DM:


   hermes pairing list
   hermes pairing approve telegram <código>


Para que arranque solo al iniciar sesión: hermes gateway install (Windows Scheduled Task).

Notas:
- Telegram usa long polling por defecto, no necesitas URL pública ni abrir puertos.
- Ya tienes el toolset hermes-telegram habilitado en config, así que el bot tendrá tools completas.
- Aviso aparte: WhatsApp ya está emparejado y conectado (cuenta +52 1 664 329 7398). La allowlist usa los JID completos: WHATSAPP_ALLOWED_USERS=5216643297398,6643297398,5216862687959,526862687959,6862687959. Ojo: WhatsApp identifica números MX como 52 1 + número, así que poner solo "6643297398" NO autoriza nada. Cualquier cambio en .env necesita `hermes gateway restart`.


