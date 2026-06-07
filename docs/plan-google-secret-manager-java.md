# Plan: Aplicación Java 17 / Spring — Integración con Google Secret Manager

> **Versión:** 1.0  
> **Autor:** Hermes Agent  
> **Stack:** Java 17 · Spring Boot 3.x · Google Cloud Secret Manager · Factory Pattern  
> **Propósito:** Documentar el ciclo de vida completo (SDLC) para construir un módulo que centralice la obtención de secretos desde Google Secret Manager.

---

## Índice

1. [Resumen Ejecutivo](#1-resumen-ejecutivo)
2. [SDLC — Ciclo de Vida del Software](#2-sdlc--ciclo-de-vida-del-software)
   - 2.1 Requisitos
   - 2.2 Diseño
   - 2.3 Implementación
   - 2.4 Pruebas
   - 2.5 Despliegue
   - 2.6 Mantenimiento
3. [Arquitectura y Patrón Factory](#3-arquitectura-y-patrón-factory)
4. [Código Base](#4-código-base)
5. [Buenas Prácticas](#5-buenas-prácticas)
6. [Referencias](#6-referencias)

---

## 1. Resumen Ejecutivo

Las aplicaciones modernas en la nube consumen secretos — API keys, credenciales de base de datos, tokens OAuth — que **nunca** deben estar en el código fuente, variables de entorno del CI, o repositorios. Google Secret Manager (GSM) es el servicio administrado de GCP para almacenar y rotar estos valores.

Este documento describe el plan completo para construir un módulo Spring Boot que:

- Lea secretos desde GSM en tiempo de inicio y bajo demanda.
- Use el **patrón Factory** para abstraer la fuente de secretos (local `application.yml` vs. GSM real), facilitando pruebas y entornos multi-stage.
- Siga el ciclo SDLC con entregables concretos en cada fase.
- Incorpore buenas prácticas: fail-fast, caching, logging estructurado, manejo de errores, y seguridad por diseño.

---

## 2. SDLC — Ciclo de Vida del Software

### 2.1 Requisitos

| ID | Requisito | Prioridad |
|---|---|---|
| RQ-01 | Obtener un secreto por nombre desde Google Secret Manager. | Alta |
| RQ-02 | Cachear el secreto en memoria para evitar llamadas repetidas a GSM. | Alta |
| RQ-03 | Proveer una implementación *mock/local* para desarrollo y tests sin conexión a GCP. | Alta |
| RQ-04 | Loguear intentos de acceso (éxito/fallo) sin exponer el valor del secreto. | Media |
| RQ-05 | Fallar rápido (fail-fast) al iniciar si un secreto obligatorio no existe. | Alta |
| RQ-06 | Soportar refresh manual o por scheduler para reflejar rotaciones de secretos. | Baja |

### 2.2 Diseño

#### Diagrama de Componentes

```
┌─────────────────────────────────────────────────┐
│                   Aplicación Spring               │
│                                                   │
│   ┌──────────────┐    ┌──────────────────────┐   │
│   │   Servicios   │───▶│  SecretManagerFactory │   │
│   │  de negocio   │    │       (interfaz)      │   │
│   └──────────────┘    └───────┬──────────────┘   │
│                               │                    │
│                ┌──────────────┼──────────────┐    │
│                ▼              ▼              ▼    │
│        ┌────────────┐ ┌────────────┐ ┌────────┐ │
│        │  GSMImpl   │ │  LocalImpl │ │GcpImpl │ │
│        │  (real)    │ │  (dev/mock)│ │(prod)  │ │
│        └────────────┘ └────────────┘ └────────┘ │
└─────────────────────────────────────────────────┘
```

#### Estrategia de Cache

- Cache **Caffeine** (compatible Spring Cache) con TTL configurable.
- Clave = nombre del secreto, valor = secreto descifrado en texto plano.
- Invalidez automática al expirar TTL; refresh lazy en el primer acceso posterior.

#### Estrategia de Configuración

```yaml
# application.yml
secret-manager:
  source: gsm                          # gsm | local | gcp
  cache-ttl-seconds: 300
  project-id: mi-proyecto-gcp
  fail-on-missing: true                # fail-fast
  secrets:
    - DB_PASSWORD
    - API_KEY_EXTERNA
```

### 2.3 Implementación

El plan de implementación sigue **TDD (Test-Driven Development)**:

| Paso | Archivo | Descripción |
|---|---|---|
| 1 | `SecretProvider.java` | Interfaz del Factory — contrato único. |
| 2 | `LocalSecretProvider.java` | Implementación que lee desde `application-secrets.yml`. |
| 3 | `GcpSecretProvider.java` | Implementación que usa la lib `google-cloud-secretmanager`. |
| 4 | `SecretManagerConfig.java` | Clase `@Configuration` que ensambla el bean condicionalmente. |
| 5 | `SecretManagerService.java` | Servicio con cache Caffeine y refresh. |
| 6 | Tests unitarios | Mock de GSM + LocalProvider en JUnit 5. |
| 7 | Test de integración | `@SpringBootTest` con Testcontainers o emulador GSM. |

### 2.4 Pruebas

| Tipo | Herramienta | Qué cubre |
|---|---|---|
| Unitarias | JUnit 5 + Mockito | Factory selecciona implementación correcta según config. |
| Unitarias | JUnit 5 | Cache expira, refresca, maneja nulos. |
| Integración | `@SpringBootTest` | Contexto Spring carga el bean correcto. |
| Integración | Testcontainers (GSM emulator) | Llamada real a GSM simulado. |
| Seguridad | Revisión manual | Ningún secreto se loguea en texto plano. |

### 2.5 Despliegue

1. **Build:** `./gradlew build` genera JAR.
2. **Container:** Docker multi-stage con `eclipse-temurin:17-jre-alpine`.
3. **GCP:** Deploy a Cloud Run con la Service Account que tenga rol `roles/secretmanager.secretAccessor`.
4. **CI/CD:** GitHub Actions:
   - `gcloud auth configure-docker`
   - Build & push a Artifact Registry
   - Deploy a Cloud Run

### 2.6 Mantenimiento

- **Dependencias:** Dependabot / Renovate para mantener `google-cloud-secretmanager` actualizado.
- **Rotación:** El cache TTL permite que secretos rotados se reflejen tras el próximo refresh.
- **Métricas:** Exportar métricas de acceso a GSM (contador de llamadas, latencia) vía Micrometer + Cloud Monitoring.

---

## 3. Arquitectura y Patrón Factory

### 3.1¿Por qué Factory aquí?

El patrón **Factory Method** permite que el *cliente* (los servicios de negocio) ignore qué implementación concreta de `SecretProvider` se está usando. Esto:

- Desacopla la lógica de negocio de la infraestructura.
- Permite intercambiar la fuente de secretos sin tocar código de negocio.
- Facilita pruebas unitarias: en lugar de mockear GSM, se inyecta `LocalSecretProvider`.
- Sigue el Principio de Inversión de Dependencias (DIP) de SOLID.

### 3.2 Diagrama UML (textual)

```
┌─────────────────────────────────────┐
│ <<interface>>                       │
│   SecretProvider                    │
├─────────────────────────────────────┤
│ + getSecret(name: String): String   │
│ + refreshSecret(name: String): void │
└─────────────────────────────────────┘
          ▲              ▲
          │              │
┌─────────┴──────┐  ┌───┴────────────┐
│ LocalProvider   │  │  GcpProvider    │
│ (dev/test)      │  │  (producción)   │
└─────────────────┘  └────────────────┘

┌─────────────────────────────────────────────┐
│ SecretManagerFactory (Spring @Configuration)│
├─────────────────────────────────────────────┤
│ + secretProvider(): SecretProvider          │
│   → lee "secret-manager.source" del config  │
│   → instancia LocalProvider o GcpProvider   │
└─────────────────────────────────────────────┘
```

### 3.3 Criterio de Selección

```
secret-manager.source = "local"     → LocalSecretProvider
secret-manager.source = "gsm"       →   GcpSecretProvider
secret-manager.source = "gcp"       →   GcpSecretProvider (alias)
```

---

## 4. Código Base

### 4.1 Interfaz — `SecretProvider.java`

```java
package com.ejemplo.secrets;

/**
 * Abstracción única para obtener secretos.
 * Implementaciones: GSM real, local (dev/test).
 */
public interface SecretProvider {

    /**
     * Retorna el valor del secreto identificado por {@code secretName}.
     * Lanza excepción si el secreto no existe y fail-fast está activo.
     */
    String getSecret(String secretName);

    /**
     * Invalida la caché para {@code secretName} y fuerza una recarga.
     */
    void refreshSecret(String secretName);
}
```

### 4.2 Implementación Local — `LocalSecretProvider.java`

```java
package com.ejemplo.secrets;

import org.springframework.core.env.Environment;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public class LocalSecretProvider implements SecretProvider {

    private final Map<String, String> secrets = new ConcurrentHashMap<>();

    public LocalSecretProvider(Environment env, List<String> secretNames) {
        secretNames.forEach(name -> {
            String value = env.getProperty("secrets." + name);
            secrets.put(name, value);
        });
    }

    @Override
    public String getSecret(String secretName) {
        String value = secrets.get(secretName);
        if (value == null) {
            throw new SecretNotFoundException(secretName);
        }
        return value;
    }

    @Override
    public void refreshSecret(String secretName) {
        // En modo local, los secretos son estáticos — no-op
    }
}
```

### 4.3 Implementación GCP — `GcpSecretProvider.java`

```java
package com.ejemplo.secrets;

import com.google.cloud.secretmanager.v1.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class GcpSecretProvider implements SecretProvider {

    private static final Logger log = LoggerFactory.getLogger(GcpSecretProvider.class);

    private final SecretManagerServiceClient client;
    private final String projectId;
    private final Cache<String, String> cache;

    public GcpSecretProvider(String projectId, Cache<String, String> cache) {
        this.projectId = projectId;
        this.cache = cache;
        this.client = SecretManagerServiceClient.create();
    }

    @Override
    public String getSecret(String secretName) {
        try {
            return cache.get(secretName, this::fetchFromGsm);
        } catch (Exception e) {
            log.error("Error al obtener secreto [{}] desde GSM", secretName);
            throw new SecretRetrievalException(secretName, e);
        }
    }

    private String fetchFromGsm(String secretName) {
        SecretVersionName versionName = SecretVersionName.of(projectId, secretName, "latest");
        AccessSecretVersionResponse response = client.accessSecretVersion(versionName);
        String value = response.getPayload().getData().toStringUtf8();
        log.info("Secreto [{}] obtenido desde GSM exitosamente", secretName);
        return value;
    }

    @Override
    public void refreshSecret(String secretName) {
        cache.invalidate(secretName);
        log.info("Caché invalidada para secreto [{}]", secretName);
    }
}
```

### 4.4 Configuración Spring — `SecretManagerConfig.java`

```java
package com.ejemplo.secrets;

import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.*;

import java.util.List;
import java.util.concurrent.TimeUnit;

@Configuration
public class SecretManagerConfig {

    @Bean
    @ConditionalOnProperty(name = "secret-manager.source", havingValue = "local", matchIfMissing = true)
    public SecretProvider localSecretProvider(
            Environment env,
            @Value("${secret-manager.secrets}") List<String> secretNames) {
        return new LocalSecretProvider(env, secretNames);
    }

    @Bean
    @ConditionalOnProperty(name = "secret-manager.source", havingValue = "gsm")
    public SecretProvider gcpSecretProvider(
            @Value("${secret-manager.project-id}") String projectId,
            @Value("${secret-manager.cache-ttl-seconds:300}") int ttlSeconds) {

        Cache<String, String> cache = Caffeine.newBuilder()
                .expireAfterWrite(ttlSeconds, TimeUnit.SECONDS)
                .recordStats()
                .build();

        return new GcpSecretProvider(projectId, cache);
    }

    @Bean
    public SecretManagerService secretManagerService(SecretProvider secretProvider) {
        return new SecretManagerService(secretProvider);
    }
}
```

### 4.5 Servicio con Cache — `SecretManagerService.java`

```java
package com.ejemplo.secrets;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

@Service
public class SecretManagerService {

    private static final Logger log = LoggerFactory.getLogger(SecretManagerService.class);

    private final SecretProvider secretProvider;

    public SecretManagerService(SecretProvider secretProvider) {
        this.secretProvider = secretProvider;
    }

    public String getSecret(String name) {
        log.debug("Solicitando secreto [{}]", name);
        return secretProvider.getSecret(name);
    }

    public void refreshSecret(String name) {
        log.info("Refresh manual solicitado para secreto [{}]", name);
        secretProvider.refreshSecret(name);
    }
}
```

---

## 5. Buenas Prácticas

### 5.1 Seguridad

| Práctica | Detalle |
|---|---|
| No loguear secretos | Siempre loguear solo el *nombre* del secreto, nunca su valor. |
| IAM mínimo | La Service Account debe tener solo `roles/secretmanager.secretAccessor`. |
| Secretos en repos | Usar `application-secrets.yml` cifrado con `jasypt-spring-boot` o `sops`. |
| Fail-fast | Si un secreto obligatorio falta al inicio, la app ni arranca. |

### 5.2 Código

| Práctica | Detalle |
|---|---|
| SOLID | Factory cumple DIP; cada clase una responsabilidad (SRP). |
| Inmutabilidad | Preferir `record` de Java 17 para DTOs. |
| Null safety | Usar `Optional` o `requireNonNull` en lugar de returns nulos. |
| Logging estructurado | Usar `{}` placeholders en SLF4J (no concatenación). |
| Pruebas | Inyectar `SecretProvider` mockeado en los tests de negocio. |

### 5.3 Infraestructura

| Práctica | Detalle |
|---|---|
| Cache con TTL | Evita llamadas repetidas a GSM; TTL corto (5 min) balancea frescura vs. costo. |
| Circuit Breaker | Opcional: si GSM falla, retornar último valor cacheado (patrón degrade). |
| Health Check | Endpoint `/actuator/health` que verifica conectividad con GSM. |

### 5.4 Manejo de Errores

```java
// SecretNotFoundException.java — cuando el secreto no existe
public class SecretNotFoundException extends RuntimeException {
    public SecretNotFoundException(String secretName) {
        super("Secreto no encontrado: " + secretName);
    }
}

// SecretRetrievalException.java — cuando GSM falla
public class SecretRetrievalException extends RuntimeException {
    public SecretRetrievalException(String secretName, Throwable cause) {
        super("Error al recuperar secreto: " + secretName, cause);
    }
}
```

### 5.5 Checklist de Calidad

- [ ] `SecretProvider` es una interfaz — cualquier implementación es intercambiable.
- [ ] Las pruebas unitarias NO hacen llamadas reales a GCP.
- [ ] No hay secretos hardcodeados en el código fuente.
- [ ] Los logs no exponen valores sensibles (revisión manual + regex en CI).
- [ ] El caché tiene un TTL razonable (< 10 minutos para entornos productivos).
- [ ] La app falla al inicio si un secreto obligatorio no existe (fail-fast).
- [ ] La configuración de la fuente de secretos (`source`) está externalizada.

---

## 6. Referencias

- [Google Cloud Secret Manager Docs](https://cloud.google.com/secret-manager/docs)
- [Spring Boot 3.x Reference](https://docs.spring.io/spring-boot/docs/current/reference/html/)
- [Java 17 Records (JEP 395)](https://openjdk.org/jeps/395)
- [Caffeine Cache](https://github.com/ben-manes/caffeine)
- [12-Factor App: Config](https://12factor.net/config)
- [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)

---

---

## 7. Autenticación — Windows + gcloud + ADC

### 7.1 Estrategia General

Google Secret Manager — como todos los servicios de GCP — requiere autenticación. El módulo Spring Boot usa **Application Default Credentials (ADC)**. Esto significa que el código **no necesita credenciales hardcodeadas**: la librería `google-cloud-secretmanager` busca automáticamente las credenciales en este orden:

1. `GOOGLE_APPLICATION_CREDENTIALS` (variable de entorno apuntando a un JSON de Service Account).
2. Credenciales de *gcloud auth application-default login* (desarrollo local).
3. Metadata server de GCP (Compute Engine, Cloud Run, GKE).

En **Windows (desarrollo local)** la ruta es la #2.

### 7.2 Setup Inicial en Windows

#### Paso 1 — Instalar Google Cloud SDK

```powershell
# PowerShell (como administrador)
(New-Object Net.WebClient).DownloadFile(
  "https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe",
  "$env:TEMP\GoogleCloudSDKInstaller.exe"
)
Start-Process "$env:TEMP\GoogleCloudSDKInstaller.exe" -Wait
```

O descargar manualmente desde:  
https://cloud.google.com/sdk/docs/install-sdk#windows

#### Paso 2 — Autenticación con gcloud auth

```powershell
# Autenticación primaria (identidad de usuario)
gcloud auth login

# Verificar
gcloud auth list
#   ─> Activa: tu-email@gmail.com
```

#### Paso 3 — Configurar el proyecto por defecto

```powershell
gcloud config set project MI-PROYECTO-ID
gcloud config list project
```

#### Paso 4 — Application Default Credentials (ADC) — el paso clave

```powershell
# Esto crea/actualiza el archivo de credenciales en:
#   %APPDATA%\gcloud\application_default_credentials.json
# (expanden a C:\Users\<tu-user>\AppData\Roaming\gcloud\...)
gcloud auth application-default login

# Verificar que ADC funciona:
gcloud auth application-default print-access-token
```

> 💡 **Diferencia clave:**  
> `gcloud auth login` autentica **a tí** como usuario para la CLI de gcloud.  
> `gcloud auth application-default login` crea las credenciales que **las librerías de Google (incluyendo Spring)** usan automáticamente vía ADC.

### 7.3 Flujo de autenticación en Windows — diagrama

```
┌─────────────────────────────────────────────────────────────┐
│                    Windows (desarrollo local)                 │
│                                                              │
│   gcloud auth login                                          │
│       └─▶ almacena refresh token en %APPDATA%\\gcloud\\       │
│             creds_aux.properties                             │
│                                                              │
│   gcloud auth application-default login                       │
│       └─▶ genera o refresca:                                  │
│             %APPDATA%\\gcloud\\application_default_credentials.json  │
│                   {                                          │
│                     "client_id": "...",                      │
│                     "client_secret": "...",                  │
│                     "refresh_token": "...",                  │
│                     "type": "authorized_user"                │
│                   }                                          │
│                                                              │
│   Aplicación Spring (ADC)                                    │
│       └─▶ google-cloud-secretmanager busca                   │
│             GOOGLE_APPLICATION_CREDENTIALS env var            │
│               ↓ (no está)                                    │
│             ADC lee application_default_credentials.json      │
│               ↓                                              │
│             Obtiene access token → llama a GSM               │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 7.4 Service Account (producción)

En **producción** (Cloud Run, GKE, Compute Engine) NO se usa autenticación de usuario.

```bash
# 1. Crear Service Account (una vez)
gcloud iam service-accounts create spring-sa \
    --display-name="Spring Boot Secret Manager SA"

# 2. Asignar rol de acceso a secretos
gcloud projects add-iam-policy-binding MI-PROYECTO-ID \
    --member="serviceAccount:spring-sa@MI-PROYECTO-ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"

# 3. Opcional — generar clave JSON si no se usa metadata server
gcloud iam service-accounts keys create ./spring-sa-key.json \
    --iam-account="spring-sa@MI-PROYECTO-ID.iam.gserviceaccount.com"
```

En Cloud Run, solo asignar la SA al recurso:

```yaml
# cloudrun.yaml
apiVersion: serving.knative.dev/v1
kind: Service
spec:
  template:
    spec:
      serviceAccountName: spring-sa@MI-PROYECTO-ID.iam.gserviceaccount.com
      containers:
        - image: gcr.io/MI-PROYECTO-ID/spring-app
```

### 7.5 Variables de Entorno en Windows

En desarrollo local con Windows, típicamente **no necesitas** `GOOGLE_APPLICATION_CREDENTIALS` porque ADC ya encuentra el archivo de `gcloud auth application-default login`. Pero si usas una Service Account key:

```powershell
# PowerShell — establecer variable de entorno (solo sesión actual)
$env:GOOGLE_APPLICATION_CREDENTIALS = "C:\ruta\spring-sa-key.json"

# cmd — equivalente
set GOOGLE_APPLICATION_CREDENTIALS=C:\ruta\spring-sa-key.json

# Persistente a nivel de usuario (PowerShell)
[Environment]::SetEnvironmentVariable(
  "GOOGLE_APPLICATION_CREDENTIALS",
  "C:\ruta\spring-sa-key.json",
  "User"
)
```

Para IntelliJ IDEA en Windows, añadir en **Run → Edit Configurations → Environment variables**:

```
GOOGLE_APPLICATION_CREDENTIALS=C:\Users\tu-user\.config\gcloud\application_default_credentials.json
```

### 7.6 Código — Integración ADC en Spring

El módulo no necesita código adicional para ADC. La dependencia Maven/Gradle lo resuelve automáticamente:

```groovy
// build.gradle
implementation platform('com.google.cloud:libraries-bom:26.32.0')
implementation 'com.google.cloud:google-cloud-secretmanager'
```

La clase `GcpSecretProvider` (sección 4.3) llama a `SecretManagerServiceClient.create()` que internamente usa ADC para obtener las credenciales. Zero configuración adicional.

### 7.7 Verificación Rápida en Windows

```powershell
# 1. Verificar que gcloud está autenticado
gcloud auth list

# 2. Verificar que ADC existe
Get-ChildItem "$env:APPDATA\gcloud\application_default_credentials.json" -ErrorAction SilentlyContinue

# 3. Probar acceso a un secreto desde CLI (buen smoke test)
gcloud secrets versions access latest --secret=MI-SECRETO

# 4. (Opcional) Verificar que la app Spring levanta con ADC
cd C:\ruta\del\proyecto
.\gradlew bootRun
# → En logs debe aparecer: "Secreto [X] obtenido desde GSM exitosamente"
```

### 7.8 Troubleshooting en Windows

| Problema | Causa | Solución |
|---|---|---|
| `java.io.IOException: The Application Default Credentials are not available.` | ADC no configurado | Ejecutar `gcloud auth application-default login` |
| `403 Secret Manager API disabled` | API no habilitada en el proyecto | `gcloud services enable secretmanager.googleapis.com` |
| `PERMISSION_DENIED` | La SA o usuario no tiene permisos | Verificar rol `secretmanager.secretAccessor` |
| `com.google.api.gax.rpc.UnauthenticatedException` | Token expirado | Re-ejecutar `gcloud auth application-default login` (o verificar hora del sistema) |
| `java.io.FileNotFoundException` (ADC JSON) | `GOOGLE_APPLICATION_CREDENTIALS` apunta a ruta incorrecta | Corregir la variable de entorno; o borrarla y dejar que ADC busque en `%APPDATA%` |

---

> **Fin del documento.**  
> Este plan cubre las fases del SDLC, el patrón Factory para abstraer la fuente de secretos, las buenas prácticas de seguridad, código e infraestructura, y la autenticación desde Windows usando gcloud + ADC.
