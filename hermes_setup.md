# Hermes Setup & DeepSeek Configuration

## Installation Details
- **Hermes Installation Path:** `C:\Users\e4dev\AppData\Local\hermes`
- **Agent Code:** `C:\Users\e4dev\AppData\Local\hermes\hermes-agent`
- **Binaries (uv, uvx):** `C:\Users\e4dev\AppData\Local\hermes\bin`

## DeepSeek Configuration
To use DeepSeek models in Hermes, you need to configure your API key.

### 1. Obtain API Key
Get your API key from the [DeepSeek Platform](https://platform.deepseek.com/).

### 2. Configure Environment Variable
Add the following line to your `.env` file located at `C:\Users\e4dev\AppData\Local\hermes\.env`:

```env
DEEPSEEK_API_KEY=your_deepseek_api_key_here
```

### 3. Available Models
You can then use the following models in Hermes:
- `deepseek-chat` (DeepSeek V3)
- `deepseek-reasoner` (DeepSeek R1 / V4 Thinking)

### 4. Configuration File
The main configuration file for Hermes is located at:
`C:\Users\e4dev\AppData\Local\hermes\config.yaml`

You can change the default model there by updating the `model.default` field.
## Configuración y Desconfiguración de Mensajería (Manual)

Sigue estos pasos para gestionar manualmente WhatsApp y otros servicios de mensajería (Telegram, Discord, Slack, etc.) utilizando las rutas de configuración de Hermes.

### 1. Localización de Archivos Clave
- **Archivo de Configuración:** `C:\Users\e4dev\AppData\Local\hermes\config.yaml`
- **Archivo de Variables de Entorno:** `C:\Users\e4dev\AppData\Local\hermes\.env`

### 2. WhatsApp

#### Configurar manualmente:
1. Abre `C:\Users\e4dev\AppData\Local\hermes\.env` y añade (si es requerido por tu proveedor/gateway):
   ```env
   WHATSAPP_API_KEY=tu_clave_aqui
   ```
2. Abre `C:\Users\e4dev\AppData\Local\hermes\config.yaml` y localiza la sección `whatsapp:`.
3. Configura los parámetros necesarios. Si deseas habilitarlo con valores por defecto, asegúrate de que no esté vacío:
   ```yaml
   whatsapp:
     enabled: true
   ```

#### Desconfigurar manualmente:
1. Abre `C:\Users\e4dev\AppData\Local\hermes\config.yaml`.
2. Cambia `enabled: true` a `enabled: false` o simplemente deja la sección vacía:
   ```yaml
   whatsapp: {}
   ```
3. (Opcional) Elimina las variables `WHATSAPP_*` de tu archivo `.env`.

### 3. Telegram / Discord / Otros

#### Configurar manualmente:
1. Obtén el token o API Key del servicio (ej. BotFather para Telegram).
2. Añade la credencial al archivo `C:\Users\e4dev\AppData\Local\hermes\.env`:
   ```env
   TELEGRAM_BOT_TOKEN=tu_token_aqui
   DISCORD_TOKEN=tu_token_aqui
   ```
3. Ajusta las preferencias (como canales permitidos o reacciones) en las secciones correspondientes (`telegram:`, `discord:`, etc.) dentro de `C:\Users\e4dev\AppData\Local\hermes\config.yaml`.

#### Desconfigurar manualmente:
1. Elimina el token correspondiente del archivo `C:\Users\e4dev\AppData\Local\hermes\.env`.
2. Reinicia el agente Hermes para aplicar los cambios.
