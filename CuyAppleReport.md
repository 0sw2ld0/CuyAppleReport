# CuyAppleReport (app nativa macOS)

App nativa de **macOS** hecha en **SwiftUI** para **monitorear el feedback de TestFlight** (comentarios con capturas de pantalla y reportes de errores) de las apps de Apple a las que se tiene acceso, con exportación a **CSV, Excel y PDF**.

---

## 1. Objetivo

Hoy el feedback de TestFlight solo se ve en App Store Connect o en Xcode Organizer, uno por uno y sin forma de exportarlo. CuyAppleReport:

1. Se conecta a App Store Connect de **dos formas**, a elegir en el formulario de conexión:
   - **Iniciar sesión con Apple ID** (modo sesión): el usuario inicia sesión en la web de App Store Connect dentro de la app y se usan sus mismos permisos. **No requiere API key**, así que sirve para usuarios con rol *Gestor de apps* que no pueden crear keys.
   - **API key (`.p8`)** (modo API key): usa la API oficial, arrastrando el `.p8` desde Finder. Es la opción más estable si un Admin la habilita.
2. Sincroniza y guarda localmente **todos** los comentarios, capturas y crashes (con su log).
3. Los muestra en una ventana con dashboard, listados y filtros para monitorearlos día a día.
4. Avisa con **notificaciones de macOS** cuando llega feedback nuevo y muestra un contador en la **barra de menús**.
5. Exporta cualquier vista filtrada a **CSV, Excel (.xlsx) y PDF**.

### Usuario objetivo
QA, PM o desarrollador que necesita revisar el feedback de los testers, darle seguimiento y compartir reportes con el equipo o el cliente.

---

## 2. Alcance (MVP)

| # | Funcionalidad | Prioridad |
|---|---|---|
| 1 | Onboarding / Ajustes: selector de modo de conexión (**Apple ID** o **API key**) | Alta |
| 1a | Modo sesión: ventana de login de App Store Connect (`WKWebView`), selección de equipo y detección de sesión expirada | Alta |
| 1b | Modo API key: formulario de credenciales con drag & drop del `.p8` | Alta |
| 2 | Botón "Probar conexión" (en ambos modos) | Alta |
| 3 | Selección de la app o apps a monitorear | Alta |
| 4 | Sincronización manual (⌘R) y automática en segundo plano | Alta |
| 5 | Dashboard con métricas y gráficas (Swift Charts) | Alta |
| 6 | Listado de comentarios (galería o tabla) con filtros | Alta |
| 7 | Listado de errores (crashes) con visor de log | Alta |
| 8 | Inspector de detalle de cada comentario o error | Alta |
| 9 | Exportar a CSV / Excel / PDF | Alta |
| 10 | Estado de seguimiento (Nuevo / En revisión / Resuelto / Ignorado) y notas internas | Media |
| 11 | Notificaciones del sistema cuando llega feedback nuevo | Media |
| 12 | Ícono en la barra de menús (MenuBarExtra) con resumen y "Sincronizar ahora" | Media |
| 13 | Abrir al iniciar sesión | Baja |

---

## 3. Stack

| Capa | Tecnología | Motivo |
|---|---|---|
| Plataforma | **macOS 14 Sonoma o posterior** | Permite usar SwiftData, `Table`, `Inspector` y Swift Charts modernos |
| Lenguaje / UI | **Swift 6 + SwiftUI** | Nativo, con concurrencia estricta |
| Persistencia | **SwiftData** | Local, integrado y sin dependencias |
| Secretos | **Keychain** (`Security.framework`) | La clave `.p8` nunca toca el disco en texto plano |
| JWT ES256 | **CryptoKit**: `P256.Signing.PrivateKey(pemRepresentation:)` | Firma nativa sin librerías de terceros (modo API key) |
| Login web | **WebKit**: `WKWebView` + `WKWebsiteDataStore(forIdentifier:)` | Login real de Apple (con 2FA) y sesión persistente aislada por conexión (modo sesión) |
| Red | `URLSession` + `async/await` | |
| Gráficas | **Swift Charts** | |
| Tablas | `SwiftUI.Table` | Columnas ordenables, selección múltiple y menú contextual |
| Drag & drop | `.dropDestination(for: URL.self)` + `.fileImporter` | Arrastrar desde Finder o seleccionar con el panel nativo |
| CSV | Generador propio (`String` UTF-8 con BOM) | Trivial, sin dependencias |
| Excel | [`libxlsxwriter`](https://github.com/jmcnamara/libxlsxwriter) vía SPM | Escribe `.xlsx` real con varias hojas, estilos e imágenes |
| PDF | `ImageRenderer` + `CGContext` (PDF) / PDFKit | Renderiza vistas SwiftUI como páginas PDF |
| Segundo plano | `NSBackgroundActivityScheduler` | Sincronización periódica eficiente en energía |
| Notificaciones | `UserNotifications` | Aviso de feedback nuevo |
| Arranque | `SMAppService.mainApp` | Abrir al iniciar sesión |

**Dependencias externas:** solo `libxlsxwriter`. Todo lo demás es framework de Apple.

---

## 4. Configuración: formulario de conexión con Apple

Aparece como **onboarding** la primera vez y después en **Ajustes (⌘,)** → pestaña *Conexión*.

### Selector de modo

Lo primero del formulario es un `Picker` segmentado con dos opciones:

| Modo | Para quién | Requiere |
|---|---|---|
| **Iniciar sesión con Apple ID** (por defecto) | Cualquier usuario que ya ve el feedback en la web, incluido el rol *Gestor de apps* | Solo su Apple ID y el 2FA |
| **API key (.p8)** | Equipos donde un Admin generó una key (individual o de equipo) | Issuer ID (solo keys de equipo), Key ID y archivo `.p8` |

Campos comunes a ambos modos: **Nombre de la conexión** y **Sincronización** (Manual / 15 min / 1 h / 6 h / 24 h; en modo sesión el mínimo es 1 h).

```
┌─ Ajustes ─────────────────────────────────────────────────────┐
│  [ Conexión ]  [ Apps ]  [ Sincronización ]  [ General ]      │
├───────────────────────────────────────────────────────────────┤
│  Nombre   [ CuyCoders – Cuenta principal                   ]  │
│                                                               │
│  Modo     ( ● Iniciar sesión con Apple ID | ○ API key (.p8) ) │
│                                                               │
│      …campos del modo elegido (4.1 o 4.2)…                    │
└───────────────────────────────────────────────────────────────┘
```

---

### 4.1 Modo sesión: Iniciar sesión con Apple ID

La app muestra la **página de login real de Apple** dentro de una ventana con `WKWebView`. El usuario escribe su Apple ID, su contraseña y el código 2FA directamente en la web de Apple. **CuyAppleReport nunca ve ni guarda la contraseña.** Cuando el login termina, la app usa esa misma sesión web para leer los datos, con exactamente los permisos que el usuario tiene en la web.

#### Flujo

```
[ Iniciar sesión con Apple ]
        │
        ▼
Ventana modal (WKWebView) → https://appstoreconnect.apple.com/login
        │  el usuario hace login + 2FA en la página de Apple
        ▼
La app detecta sesión válida (GET /olympus/v1/session → 200)
        │
        ├─ ¿Pertenece a varios equipos? → selector de equipo
        ▼
Cierra la ventana → "✓ Sesión iniciada como ana@example.com · Equipo CuyCoders"
        │
        ▼
Probar conexión → lista de apps → selección de apps a monitorear
```

#### Detalles de implementación

- **Almacén de sesión aislado por conexión.** Cada conexión usa su propio `WKWebsiteDataStore(forIdentifier: connection.id)` (macOS 14+). Es persistente, así que la sesión sobrevive a reinicios de la app, y no se mezcla con Safari ni con otras conexiones.
- **Detección del login.** Tras cada navegación terminada (`webView(_:didFinish:)`), la app ejecuta `fetch('/olympus/v1/session')` dentro del webview. Cuando responde `200` con datos del usuario, el login terminó. De esa respuesta se toman el nombre, el email, el equipo actual (`provider`) y los equipos disponibles (`availableProviders`).
- **Selección de equipo.** Si hay más de un equipo, se muestra un `Picker`. El cambio de equipo se hace con la misma llamada que usa la web: `POST /olympus/v1/providerSwitchRequests` con un cuerpo JSON:API que referencia al `providers` elegido (ver sección 6.1). Después se vuelve a leer `/olympus/v1/session` para confirmar el cambio.
- **El equipo activo es global para la sesión.** Si el usuario cambia de equipo en Safari o Chrome, eso no afecta a la app porque su almacén de sesión es independiente. Pero si dos conexiones de la app compartieran almacén, sí se afectarían, y por eso cada conexión tiene el suyo. Antes de cada sincronización se verifica que `provider.providerId` coincida con el equipo configurado y, si no coincide, se vuelve a cambiar.
- **La app no inyecta nada en la página de login.** Solo observa la navegación y hace la comprobación de sesión después de cada carga.
- **Botón "Cerrar sesión".** Borra el almacén de esa conexión (`WKWebsiteDataStore.remove(forIdentifier:)`).

#### Cómo se hacen las peticiones (`WebSessionTransport`)

En lugar de extraer las cookies y copiarlas a `URLSession`, que es frágil por los tokens CSRF y los encabezados propios de la web, las peticiones se ejecutan **dentro de un `WKWebView` oculto** que comparte el mismo almacén de sesión. Así viajan exactamente igual que las que hace la web de App Store Connect.

```swift
@MainActor
final class WebSessionTransport: ASCTransport {
    private let webView: WKWebView   // oculto, con https://appstoreconnect.apple.com cargado

    init(dataStore: WKWebsiteDataStore) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: config)
    }

    func get(_ path: String) async throws -> Data {
        let js = """
        const r = await fetch(url, { credentials: 'include', headers: { 'Accept': 'application/json' } });
        return { status: r.status, body: await r.text() };
        """
        let result = try await webView.callAsyncJavaScript(
            js, arguments: ["url": "/iris" + path], contentWorld: .defaultClient
        ) as? [String: Any]

        let status = result?["status"] as? Int ?? 0
        let body = result?["body"] as? String ?? ""
        switch status {
        case 200..<300: return Data(body.utf8)
        case 401:       throw ASCError.sessionExpired
        case 403:       throw ASCError.forbidden
        case 429:       throw ASCError.rateLimited
        default:        throw ASCError.http(status, body)
        }
    }
}
```

- `contentWorld: .defaultClient` aísla el código de la app de los scripts de la página.
- Las **imágenes de las capturas** vienen como URLs firmadas del CDN de Apple, así que se descargan con `URLSession` normal, sin cookies.

#### Sesión expirada

- Si cualquier petición devuelve `401`, la conexión pasa a estado **"Sesión expirada"**:
  - Se pausa la sincronización automática.
  - Se envía una notificación de macOS: "Tu sesión de App Store Connect expiró. Vuelve a iniciar sesión".
  - Aparece un banner en la ventana principal y un aviso en la barra de menús con el botón **Iniciar sesión**.
- Al volver a iniciar sesión se retoma la sincronización incremental desde `lastSyncAt`, así que no se pierde nada.
- Los datos ya sincronizados siguen disponibles sin conexión.

#### Wireframe (modo sesión)

```
┌─ Ajustes ─────────────────────────────────────────────────────┐
│  Modo     ( ● Iniciar sesión con Apple ID | ○ API key (.p8) ) │
│                                                               │
│   Sin sesión:                                                 │
│        [  Iniciar sesión con Apple  ]                         │
│        Se abrirá la página de App Store Connect. Tu           │
│        contraseña se escribe en la web de Apple; la app       │
│        nunca la ve ni la guarda.                              │
│                                                               │
│   Con sesión:                                                 │
│        ✓ ana@example.com                                    │
│        Equipo  [ CuyCoders S.A.C.                    ▾ ]      │
│        Sesión válida · verificada hace 3 min                  │
│        [ Probar conexión ]  [ Cerrar sesión ]                 │
└───────────────────────────────────────────────────────────────┘
```

---

### 4.2 Modo API key (.p8)

#### Campos

| Campo | Control | Validación | Ayuda mostrada al usuario |
|---|---|---|---|
| Tipo de key | `Picker` | Equipo / Individual | Las keys individuales no usan Issuer ID |
| Issuer ID | `TextField` | UUID válido (solo keys de equipo) | App Store Connect → Usuarios y acceso → Integraciones → App Store Connect API |
| Key ID | `TextField` | 10 caracteres alfanuméricos | Aparece junto a la key en la misma pantalla |
| Private Key (`.p8`) | **zona de drop + botón "Seleccionar…"** | extensión `.p8`, formato PEM válido | "Arrastra aquí tu AuthKey_XXXX.p8 desde Finder" |

Incluye un botón **"Abrir App Store Connect"** que lleva a la página de API keys en el navegador.

#### Comportamiento del campo `.p8`

```swift
// UTType para .p8, declarado como Imported Type en Info.plist
extension UTType {
    static let p8Key = UTType(importedAs: "com.apple.p8-private-key", conformingTo: .data)
}

P8DropZone(state: $keyState)
    .dropDestination(for: URL.self) { urls, _ in
        guard let url = urls.first, url.pathExtension.lowercased() == "p8" else { return false }
        return model.loadKey(from: url)
    } isTargeted: { isHovering = $0 }
    .fileImporter(isPresented: $showPicker, allowedContentTypes: [.p8Key, .data]) { result in
        if case .success(let url) = result { model.loadKey(from: url) }
    }
```

- Zona con borde punteado, ícono `key.fill` (SF Symbol) y resaltado en azul cuando se arrastra un archivo encima (`isTargeted`).
- Al soltar el archivo:
  1. `url.startAccessingSecurityScopedResource()`
  2. Leer el contenido.
  3. Validar con `P256.Signing.PrivateKey(pemRepresentation:)`. Si falla, mostrar "El archivo no es una clave privada válida".
  4. Si el nombre tiene la forma `AuthKey_<KEYID>.p8`, **autocompletar el Key ID**.
  5. Mostrar el estado "✓ AuthKey_ABC123.p8 cargada" con un botón **Reemplazar**.
- La clave se guarda **solo al pulsar Guardar**, directamente en el Keychain. No se copia el archivo.
- Nunca se muestra el contenido de la clave.

#### Botón "Probar conexión"
1. Genera el JWT en memoria y llama a `GET /v1/apps?limit=200`.
2. Si responde bien, muestra ✅ "Conexión exitosa – N apps encontradas" y pasa a la **selección de apps** (lista con `Toggle`, ícono, nombre y bundle ID).
3. Si falla, muestra un error legible:
   - `401` → "Issuer ID, Key ID o clave privada incorrectos"
   - `403` → "La key no tiene permisos suficientes (usa rol App Manager o Admin)"
   - Sin red → "No se pudo contactar a Apple"

#### Wireframe (modo API key)

```
┌─ Ajustes ─────────────────────────────────────────────────────┐
│  Modo     ( ○ Iniciar sesión con Apple ID | ● API key (.p8) ) │
│                                                               │
│  Tipo          ( ● Equipo | ○ Individual )                    │
│  Issuer ID     [ 69a6de7f-xxxx-xxxx-xxxx-xxxxxxxxxxxx      ]  │
│  Key ID        [ ABC123DEFG                                ]  │
│                                                               │
│  Clave privada                                                │
│  ╭ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ╮     │
│            🔑  Arrastra aquí tu AuthKey_XXXX.p8               │
│  │                 [ Seleccionar… ]                     │     │
│  ╰ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ╯     │
│                                                               │
│  ↗ Abrir App Store Connect                                    │
│                         [ Probar conexión ]  [ Guardar ]      │
└───────────────────────────────────────────────────────────────┘
```

---

## 5. Seguridad

### Modo sesión
- La contraseña del Apple ID y el código 2FA se escriben **solo en la página de Apple**. La app no lee campos de formulario, no inyecta scripts en la página de login y no guarda credenciales.
- La sesión (cookies) vive en un `WKWebsiteDataStore` propio de cada conexión, dentro del contenedor sandbox de la app. No se copia a SwiftData, no se escribe en logs y nunca se exporta.
- Los scripts de la app se ejecutan en `WKContentWorld.defaultClient`, aislados de los scripts de la página.
- El webview solo navega a dominios `*.apple.com`. Cualquier otro enlace se abre en el navegador del sistema (`decidePolicyFor navigationAction`).
- **Cerrar sesión** o **Eliminar conexión** borra el almacén de sesión de esa conexión.
- Uso prudente: en modo sesión la sincronización tiene un intervalo mínimo de **1 h** y como máximo 2 peticiones simultáneas, para parecerse al uso normal de la web.

### Modo API key
- La clave `.p8` se guarda en el **Keychain** (`kSecClassGenericPassword`, `service = "com.cuycoders.CuyAppleReport"`, `account = keyId`) con `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, para que no se sincronice con iCloud.
- El Issuer ID y el Key ID no son secretos: van en SwiftData.
- El JWT se genera en memoria con vida de 20 min (el máximo que permite Apple) y se reutiliza hasta 1 min antes de expirar.

### General
- La app va en **App Sandbox** con los entitlements mínimos:
  - `com.apple.security.network.client`
  - `com.apple.security.files.user-selected.read-write`, para leer el `.p8` y guardar las exportaciones
- El email de los testers es dato personal: se muestra en la app, pero al exportar existe la opción **"Anonimizar emails"**.
- Al pulsar **Eliminar conexión** se borran el ítem del Keychain o el almacén de sesión, y todos los datos locales de esa conexión.

---

## 6. Integración con App Store Connect

### Dos transportes, un solo cliente

Las rutas y la forma del JSON son las mismas en la API oficial y en la API interna de la web (`/iris`). Solo cambia **cómo se autentica cada petición**. Por eso todo el código de sincronización, mapeo y exportación es común, y solo cambia el transporte:

```swift
protocol ASCTransport: Sendable {
    /// `path` empieza con /v1/…  Ej: "/v1/apps/123/betaFeedbackCrashSubmissions?limit=200"
    func get(_ path: String) async throws -> Data
}

// Modo API key → https://api.appstoreconnect.apple.com/v1/… + Authorization: Bearer <JWT>
final class APIKeyTransport: ASCTransport { … }

// Modo sesión → https://appstoreconnect.apple.com/iris/v1/… con la sesión del WKWebView
final class WebSessionTransport: ASCTransport { … }   // ver sección 4.1

actor AppStoreConnectClient {
    init(transport: ASCTransport)
    func apps() async throws -> [AppDTO]
    func screenshotSubmissions(appId: String, since: Date?) -> AsyncThrowingStream<ScreenshotDTO, Error>
    func crashSubmissions(appId: String, since: Date?) -> AsyncThrowingStream<CrashDTO, Error>
    func crashLog(submissionId: String) async throws -> String
}
```

| | Modo API key | Modo sesión |
|---|---|---|
| Base URL | `https://api.appstoreconnect.apple.com` | `https://appstoreconnect.apple.com/iris` |
| Autenticación | JWT ES256 en `Authorization` | Cookies de sesión del `WKWebView` |
| Permisos | Rol de la key | Rol del usuario (lo mismo que ve en la web) |
| Duración | Indefinida (hasta revocar la key) | Hasta que Apple expire la sesión (días o semanas) |
| Oficial | Sí | No: API interna de la web, puede cambiar |

> **Paginación en modo sesión:** `links.next` llega como URL absoluta de `/iris/v1/…`. `WebSessionTransport` la convierte en ruta relativa antes de pedirla.

### JWT con CryptoKit (modo API key)

```swift
import CryptoKit
import Foundation

struct AppleTokenProvider {
    let issuerId: String?   // nil = key individual
    let keyId: String
    let privateKey: P256.Signing.PrivateKey

    func makeToken(now: Date = .now) throws -> String {
        let header = ["alg": "ES256", "kid": keyId, "typ": "JWT"]
        let iat = Int(now.timeIntervalSince1970)
        var payload: [String: Any] = ["iat": iat, "exp": iat + 20 * 60, "aud": "appstoreconnect-v1"]
        if let issuerId { payload["iss"] = issuerId }   // key de equipo
        else { payload["sub"] = "user" }                // key individual
        let h = try JSONSerialization.data(withJSONObject: header).base64URLEncoded()
        let p = try JSONSerialization.data(withJSONObject: payload).base64URLEncoded()
        let signingInput = "\(h).\(p)"
        // rawRepresentation = r||s (64 bytes), justo el formato que exige JWS ES256
        let sig = try privateKey.signature(for: Data(signingInput.utf8)).rawRepresentation
        return "\(signingInput).\(sig.base64URLEncoded())"
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

### Endpoints utilizados

Las rutas son relativas a la base URL de cada modo (en modo sesión van precedidas por `/iris`).

| Uso | Método y ruta |
|---|---|
| Listar apps | `GET /v1/apps?limit=200` |
| Comentarios con captura | `GET /v1/apps/{appId}/betaFeedbackScreenshotSubmissions?limit=200&include=build,tester` |
| Errores (crashes) | `GET /v1/apps/{appId}/betaFeedbackCrashSubmissions?limit=200&include=build,tester` |
| Log de un crash | `GET /v1/betaFeedbackCrashSubmissions/{id}/crashLog` |
| Detalle de una build | `GET /v1/builds/{buildId}` (versión, número de build) |
| Sesión y equipos (solo modo sesión) | `GET /olympus/v1/session` (sin prefijo `/iris`) |

### Reglas del cliente (`AppStoreConnectClient`, un `actor`)
- **Paginación**: seguir `links.next` hasta que no exista. Se expone como `AsyncThrowingStream` para ir mostrando el progreso.
- **Rate limit y errores temporales**: leer el header `X-Rate-Limit`; ante un `429` o un **`503`**, reintentar con backoff exponencial (1s, 2s, 4s… máximo 5 intentos). En la fase 0 se observó que la propia web recibe `503` ocasionales en `/iris` y los reintenta.
- **Capturas**: las URLs de Apple caducan, así que se **descargan** a `~/Library/Containers/<bundle>/Data/Library/Application Support/CuyAppleReport/screenshots/{submissionId}/{n}.png`.
- **Crash logs**: se guardan en `…/crashlogs/{submissionId}.txt`.
- **Sincronización incremental**: guardar `lastSyncAt` por app y dejar de paginar al llegar a ítems con `createdDate` anterior (con un margen de solapamiento de 1 h). Se hace upsert por `id`.
- **Concurrencia**: se descargan hasta 4 imágenes o logs en paralelo con `TaskGroup`.

> Nota: los nombres exactos de los atributos (y, en modo sesión, las rutas `/iris` y los encabezados que exige la web) se validan contra respuestas reales en la **fase 0** y se ajusta el mapeo en `AppleMappers.swift`. Los DTOs son `Decodable` con campos opcionales para tolerar cambios de Apple.

### 6.1 Resultados de la fase 0 (verificado el 2026-09-23)

Se verificó con una sesión real de App Store Connect en Chrome (usuario con varios equipos), haciendo solo peticiones de lectura, salvo el cambio de equipo, que hizo el propio usuario.

| Qué | Resultado |
|---|---|
| `GET /olympus/v1/session` | ✅ `200`. Claves: `user` (`fullName`, `firstName`, `lastName`, `emailAddress`, `prsId`), `provider` (`providerId`, `publicProviderId`, `name`, `contentTypes`, `subType`), `availableProviders[]` (mismas claves), `roles[]`, `publicUserId`, entre otras |
| `GET /iris/v1/apps` | ✅ `200`. Mismo formato JSON:API que la API oficial |
| `GET /iris/v1/apps/{id}/betaFeedbackScreenshotSubmissions` | ✅ `200`. **Es exactamente la llamada que hace la web**: `?include=tester,build&fields[builds]=version,preReleaseVersion,buildBundles&limit=60` |
| `GET /iris/v1/apps/{id}/betaFeedbackCrashSubmissions` | ✅ `200`. Ninguna app del equipo de prueba tenía crashes, así que aún falta ver un ítem real y el endpoint `crashLog` |
| `GET /iris/v1/apps/{id}/betaFeedbackScreenshotSubmissionsOptions` (y `…CrashSubmissionsOptions`) | ✅ `200`. Devuelve los valores únicos para los filtros: `uniqueDeviceModels`, `uniquePreReleaseVersions`, `uniqueBuilds`, `uniqueAppPlatforms`, `uniqueDevicePlatformAndOsVersions`, `hasAppClips`. **Sirve para llenar los filtros de la UI sin recorrer todos los ítems** |
| Autenticación | ✅ Bastan las cookies de la sesión: no hizo falta ningún encabezado especial ni token CSRF para los `GET` |
| Paginación | ✅ `links.next` es una URL absoluta `https://appstoreconnect.apple.com/iris/v1/…&cursor=…`; `meta.paging` trae `total`, `limit` y `nextCursor` |
| Equipo activo | La sesión tiene **un equipo activo a la vez** y `/iris` solo devuelve las apps de ese equipo. El cambio de equipo es global para la sesión: afecta a todas las pestañas del mismo navegador |
| Cambio de equipo | Encontrado en el código de la web: `POST /olympus/v1/providerSwitchRequests` con cuerpo JSON:API `{ data: { type: "providerSwitchRequests", relationships: { provider: { data: { type: "providers", id: … } } } } }`. **No se ejecutó.** Falta confirmar si el `id` es `providerId` o `publicProviderId` (se prueba al implementar el `TeamPicker`) |
| `include` anidado (`build.preReleaseVersion`) | ❌ `400`. La versión de la app ("1.0") se obtiene aparte con `GET /iris/v1/apps/{id}/preReleaseVersions?include=builds`, y se arma un mapa build → versión |
| Imágenes | Host `tf-feedback.itunes.apple.com`, URLs firmadas con `expirationDate` (unas 2–3 semanas). Hay `screenshots[]` (original) y `sizedScreenshots[]` con `original`, `fits1024`, `fits512` y `fits256`. **Se usa `fits512` para las miniaturas y `original` para el detalle** |

#### Campos reales de `betaFeedbackScreenshotSubmissions`

`createdDate`, `comment`, `email`, `deviceModel` (ej. `iPhone16_2`), `osVersion`, `locale`, `timeZone`, `architecture`, `connectionType`, `pairedAppleWatch`, `appUptimeInMilliseconds`, `diskBytesAvailable`, `diskBytesTotal`, `batteryPercentage`, `screenWidthInPoints`, `screenHeightInPoints`, `appPlatform`, `devicePlatform`, `deviceFamily`, `buildBundleId`, `buildBundleType`, `carrier`, `mobileNetworkType`, `screenshots[]`, `sizedScreenshots[]`.
Relaciones: `build` (atributo `version` = número de build) y `tester` (`firstName`, `lastName`, `email`, `inviteType`).

> Hay campos útiles que no estaban en el modelo: `appUptimeInMilliseconds`, `architecture`, `diskBytesAvailable`/`diskBytesTotal`, `carrier`, `pairedAppleWatch` y las dimensiones de pantalla. Se agregan al modelo `Feedback` y al inspector.

#### Fixtures para tests
Respuestas de ejemplo **anonimizadas** en [`fixtures/iris/`](fixtures/iris/):
- `session_shape.json`
- `apps_page1.json` (con `links.next`)
- `screenshot_submissions.json`
- `screenshot_submissions_options.json`

#### Pendiente
- [ ] Ver un `betaFeedbackCrashSubmission` real y el formato de `GET /iris/v1/betaFeedbackCrashSubmissions/{id}/crashLog` (hace falta una app con al menos un crash reportado desde TestFlight).
- [ ] Confirmar el `id` que espera `providerSwitchRequests`.

---

## 7. Modelo de datos (SwiftData)

```swift
@Model final class Connection {
    @Attribute(.unique) var id: UUID
    var name: String
    var authMode: AuthMode             // .webSession | .apiKey
    // modo API key
    var issuerId: String?              // nil si la key es individual
    var keyId: String?                 // la clave privada vive en el Keychain
    // modo sesión (la sesión vive en WKWebsiteDataStore(forIdentifier: id))
    var accountEmail: String?
    var providerId: String?            // equipo seleccionado
    var providerName: String?
    var sessionState: SessionState     // .valid | .expired | .unknown
    var sessionCheckedAt: Date?
    var syncInterval: SyncInterval
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var apps: [MonitoredApp] = []
}

@Model final class MonitoredApp {
    @Attribute(.unique) var appleId: String
    var name: String
    var bundleId: String
    var iconURL: URL?
    var isMonitored: Bool = true
    var lastSyncAt: Date?
    var connection: Connection?
    @Relationship(deleteRule: .cascade) var feedbacks: [Feedback] = []
}

@Model final class Feedback {
    @Attribute(.unique) var appleId: String
    var kind: FeedbackKind          // .screenshot | .crash
    var comment: String?
    var testerEmail: String?
    var testerName: String?
    var deviceModel: String?
    var deviceFamily: String?
    var osVersion: String?
    var locale: String?
    var timeZone: String?
    var batteryPercentage: Int?
    var connectionType: String?
    var carrier: String?
    var architecture: String?
    var appUptimeMs: Int?
    var diskBytesAvailable: Int64?
    var diskBytesTotal: Int64?
    var screenWidthPt: Int?
    var screenHeightPt: Int?
    var pairedAppleWatch: String?
    var appVersion: String?
    var buildNumber: String?
    var createdDate: Date
    var screenshotPaths: [String] = []
    var crashLogPath: String?
    @Attribute(.externalStorage) var rawJSON: Data?   // respuesta original, para depurar
    // seguimiento interno
    var status: FeedbackStatus = .new // .new | .inReview | .resolved | .ignored
    var notes: String?
    var app: MonitoredApp?
}

@Model final class SyncRun {
    var appleAppId: String
    var startedAt: Date
    var finishedAt: Date?
    var newItems: Int
    var errorMessage: String?
}
```

---

## 8. Interfaz

Ventana principal con `NavigationSplitView` de tres columnas: **sidebar | contenido | inspector**.

```
┌──────────────┬───────────────────────────────────────────┬──────────────────┐
│ APPS         │  🔍 Buscar…   Build ▾  iOS ▾  Estado ▾    │  INSPECTOR       │
│ ● Todas      │  [▦ Galería | ☰ Tabla]      ⟳   ⤓ Export  │                  │
│ ● CuyPay     ├───────────────────────────────────────────┤  [ captura ]     │
│ ● CuyStore   │  Fecha      Tester     Comentario   iOS   │                  │
│              │  23/09 15:41 ana@…     "El botón…"  18.6  │  Comentario…     │
│ FEEDBACK     │  22/09 10:02 luis@…    "Se cierra…" 26.0  │  iPhone 16 Pro   │
│ 📊 Dashboard │  …                                        │  iOS 26.0 · 4G   │
│ 💬 Comentar. │                                           │  Build 1.4 (57)  │
│ 💥 Errores   │                                           │                  │
│              │                                           │  Estado [Nuevo▾] │
│ Últ. sync    │                                           │  Notas …         │
│ hace 5 min   │                                           │                  │
└──────────────┴───────────────────────────────────────────┴──────────────────┘
```

### 8.1 Dashboard
- Selector de rango de fechas (7 d / 30 d / 90 d / personalizado).
- **Tarjetas KPI**: Total comentarios · Total errores · Nuevos (sin revisar) · Últimos 7 días · Última sincronización.
- **Swift Charts**:
  - Feedback por día, con barras apiladas de comentarios y errores.
  - Top 5 dispositivos con más errores.
  - Top 5 versiones de iOS.
  - Errores por build, para detectar builds problemáticas.

### 8.2 Comentarios
- **Galería**: `LazyVGrid` de tarjetas con miniatura, igual que en App Store Connect.
- **Tabla**: `Table` con columnas ordenables: Fecha · Tester · Comentario · Dispositivo · iOS · Build · Estado.
- Filtros en la toolbar: build, dispositivo, versión de SO, tester, estado; búsqueda con `.searchable` sobre el comentario.
- Menú contextual: Cambiar estado · Copiar comentario · Mostrar captura en Finder · Exportar selección.
- Quick Look (barra espaciadora) sobre la captura seleccionada.

### 8.3 Errores
- `Table` con las mismas columnas y los mismos filtros.
- Agrupar por build o por dispositivo.
- En el inspector: visor del log con fuente monoespaciada, botones **Copiar** y **Mostrar en Finder**, y opción **Abrir en Console.app**.

### 8.4 Inspector
- Capturas a tamaño completo (clic para abrir en Quick Look).
- Comentario completo y metadatos del dispositivo (modelo, SO, batería, conexión, idioma, zona horaria).
- Estado (`Picker`) y notas internas (`TextEditor`).

### 8.5 Barra de menús (`MenuBarExtra`)
- Ícono con un indicador si hay feedback nuevo.
- Resumen por app: "CuyPay: 3 comentarios, 1 error nuevos".
- Opciones: **Sincronizar ahora** · **Abrir CuyAppleReport** · **Salir**.
- En modo sesión, si la sesión expiró, el ícono muestra una advertencia y el menú ofrece **Iniciar sesión de nuevo** en primer lugar.

### 8.6 Atajos de teclado
| Atajo | Acción |
|---|---|
| ⌘R | Sincronizar ahora |
| ⌘E | Exportar… |
| ⌘F | Buscar |
| ⌘1 / ⌘2 / ⌘3 | Dashboard / Comentarios / Errores |
| ⌘⌥I | Mostrar u ocultar el inspector |
| ⌘, | Ajustes |

---

## 9. Exportación

Menú **Archivo → Exportar… (⌘E)** y botón en la toolbar. Abre una hoja (`sheet`) con:
- Formato: **CSV / Excel / PDF**
- Alcance: vista actual con filtros · solo la selección · todo
- Incluir: comentarios, errores, capturas (Excel y PDF), crash logs (carpeta aparte)
- ☐ Anonimizar emails

Después se abre `NSSavePanel` (o `.fileExporter`) con el nombre sugerido `CuyAppleReport_<App>_<YYYY-MM-DD>.<ext>`. Al terminar se ofrece **Mostrar en Finder**.

### CSV
- UTF-8 **con BOM** y separador `,`, con escape correcto de comillas y saltos de línea.
- Columnas: `id, tipo, fecha, app, version, build, tester_email, tester_nombre, dispositivo, os, idioma, comentario, estado, notas, capturas`.

### Excel (.xlsx, con libxlsxwriter)
- Hoja **Resumen**: KPIs, filtros aplicados y fecha de generación.
- Hoja **Comentarios**: autofiltro, encabezado fijo, anchos de columna ajustados y miniatura de la captura embebida (opcional).
- Hoja **Errores**: primeros 500 caracteres del log y la ruta al archivo completo.
- Hojas **Por dispositivo** y **Por build**: tablas agregadas.

### PDF
- Cada página se construye como una vista SwiftUI (`ReportCoverPage`, `ReportSummaryPage`, `FeedbackCardPage`…) y se renderiza con `ImageRenderer` en un `CGContext` PDF de tamaño A4 o Carta.
- **Portada**: logo de CuyCoders, nombre de la app, rango de fechas y fecha de generación.
- **Resumen**: KPIs y gráficas (las mismas vistas de Swift Charts).
- **Comentarios**: tarjetas con miniatura, texto y metadatos.
- **Errores**: tabla, más un anexo opcional con los logs.
- Pie de página con número de página y la leyenda "Confidencial".

---

## 10. Sincronización en segundo plano

- `NSBackgroundActivityScheduler` con `interval` según el ajuste elegido, `tolerance` del 10 % y `qualityOfService = .utility`.
- Solo corre mientras la app está abierta, incluso si solo está en la barra de menús.
- Con **Abrir al iniciar sesión** activado (`SMAppService.mainApp.register()`), la app arranca oculta, solo en la barra de menús.
- Al terminar, si hay ítems nuevos:
  - Envía una notificación: "CuyPay: 3 comentarios nuevos, 1 error". Al hacer clic se abre la app filtrada en "Nuevos".
  - Actualiza el badge del Dock y el indicador de la barra de menús.
- Cada ejecución se registra en `SyncRun` (Ajustes → Sincronización → Historial).
- **Modo sesión:**
  - El `WKWebView` oculto se crea al iniciar la sincronización y se libera al terminar.
  - Antes de sincronizar se comprueba la sesión (`/olympus/v1/session`). Si expiró, no se hace ninguna otra petición y se pasa al estado "Sesión expirada" (sección 4.1).
  - Intervalo mínimo de 1 h y como máximo 2 peticiones simultáneas.

---

## 11. Estructura del proyecto (Xcode)

```
CuyAppleReport/
├── CuyAppleReport.xcodeproj
├── CuyAppleReport/
│   ├── App/
│   │   ├── CuyAppleReportApp.swift        # WindowGroup + Settings + MenuBarExtra
│   │   ├── AppState.swift                 # @Observable estado global
│   │   └── Commands.swift                 # menús y atajos
│   ├── Features/
│   │   ├── Onboarding/
│   │   ├── Settings/
│   │   │   ├── ConnectionSettingsView.swift
│   │   │   ├── AuthModePicker.swift
│   │   │   ├── AppleLoginWindow.swift     # WKWebView de login + detección de sesión
│   │   │   ├── TeamPicker.swift
│   │   │   ├── P8DropZone.swift
│   │   │   ├── AppsSettingsView.swift
│   │   │   └── SyncSettingsView.swift
│   │   ├── Dashboard/
│   │   │   ├── DashboardView.swift
│   │   │   └── Charts/…
│   │   ├── Feedback/
│   │   │   ├── ScreenshotsView.swift      # galería + tabla
│   │   │   ├── CrashesView.swift
│   │   │   ├── FeedbackInspector.swift
│   │   │   ├── CrashLogViewer.swift
│   │   │   └── FeedbackFilters.swift
│   │   ├── Export/
│   │   │   ├── ExportSheet.swift
│   │   │   ├── CSVExporter.swift
│   │   │   ├── XLSXExporter.swift
│   │   │   └── PDF/…                      # páginas SwiftUI del reporte
│   │   └── MenuBar/MenuBarView.swift
│   ├── Services/
│   │   ├── AppStoreConnect/
│   │   │   ├── ASCTransport.swift         # protocolo + ASCError
│   │   │   ├── APIKeyTransport.swift      # api.appstoreconnect.apple.com + JWT
│   │   │   ├── WebSessionTransport.swift  # /iris vía WKWebView oculto
│   │   │   ├── WebSessionStore.swift      # WKWebsiteDataStore por conexión, logout
│   │   │   ├── AppleTokenProvider.swift   # JWT ES256 con CryptoKit
│   │   │   ├── AppStoreConnectClient.swift
│   │   │   ├── DTOs.swift
│   │   │   └── AppleMappers.swift
│   │   ├── SyncService.swift
│   │   ├── BackgroundScheduler.swift
│   │   ├── KeychainStore.swift
│   │   ├── FileStore.swift                # capturas y logs en Application Support
│   │   └── NotificationService.swift
│   ├── Models/                            # SwiftData @Model
│   ├── Resources/Assets.xcassets
│   ├── Info.plist                         # UTType importado para .p8
│   └── CuyAppleReport.entitlements
└── CuyAppleReportTests/
    ├── TokenProviderTests.swift
    ├── ClientTests.swift                  # con un MockTransport
    ├── MappersTests.swift                 # con JSON de ejemplo de Apple
    └── ExportersTests.swift
```

---

## 12. Distribución

- **Interna (recomendada para empezar):** firmar con **Developer ID Application**, notarizar con `xcrun notarytool` y distribuir un `.dmg`. Los usuarios solo lo arrastran a Aplicaciones.
- **Opcional:** actualizaciones automáticas con [Sparkle](https://sparkle-project.org).
- **Mac App Store:** es posible porque la app ya va en sandbox, pero no es necesario para uso interno.

---

## 13. Plan de trabajo

| Fase | Entregable | Estimación |
|---|---|---|
| 0 | **Verificación del modo sesión**: con la sesión iniciada en el navegador, revisar en la pestaña Red las peticiones de la página de feedback. Confirmar las rutas `/iris/v1/…`, los encabezados necesarios, la paginación, la forma del JSON, `/olympus/v1/session` y el cambio de equipo. Guardar respuestas de ejemplo (sin datos personales) como fixtures de los tests | 0,5–1 día |
| 1 | Proyecto Xcode y SwiftData. Selector de modo. **Modo sesión**: ventana de login, detección de sesión, selector de equipo y cerrar sesión. **Modo API key**: Keychain, drag & drop del `.p8`, JWT (equipo e individual). "Probar conexión" y selección de apps en ambos modos | 3–4 días |
| 2 | `ASCTransport` con sus dos implementaciones, cliente común, sincronización completa e incremental, manejo de sesión expirada, descarga de capturas y logs, tests con `MockTransport` | 3–4 días |
| 3 | Ventana principal: sidebar, galería, tabla, filtros, inspector, estados y notas, Quick Look | 3–4 días |
| 4 | Dashboard con Swift Charts | 1–2 días |
| 5 | Exportación CSV, Excel y PDF | 3 días |
| 6 | Sincronización en segundo plano, notificaciones, barra de menús, abrir al iniciar sesión | 2 días |
| 7 | Íconos, pulido, firma, notarización y `.dmg` | 1–2 días |
| 8 (opcional) | Varias conexiones o cuentas, Sparkle, envío a Slack, reseñas del App Store | — |

---

## 14. Criterios de aceptación

**Modo sesión**
- [ ] Con un usuario *Gestor de apps* sin API key, puedo iniciar sesión (con 2FA) dentro de la app y sincronizar el mismo feedback que veo en la web.
- [ ] La app nunca guarda ni registra la contraseña: el login ocurre solo en la página de Apple.
- [ ] La sesión se mantiene al cerrar y volver a abrir la app.
- [ ] Si pertenezco a varios equipos, puedo elegir cuál monitorear.
- [ ] Cuando la sesión expira, recibo una notificación, la sincronización se pausa y, al volver a iniciar sesión, continúa sin perder ni duplicar datos.
- [ ] "Cerrar sesión" borra la sesión: al reabrir la app pide login otra vez.

**Modo API key**
- [ ] Puedo arrastrar el `.p8` desde Finder (o seleccionarlo) y el Key ID se autocompleta si el nombre del archivo lo trae.
- [ ] Un `.p8` inválido muestra un error claro y no se guarda.
- [ ] Funciona tanto con keys de equipo (Issuer ID) como con keys individuales.
- [ ] La clave privada solo existe en el Keychain: no aparece en SwiftData, en logs ni en archivos.

**General**
- [ ] "Probar conexión" informa éxito o un error entendible en menos de 5 s, en ambos modos.
- [ ] La sincronización trae el 100 % de los comentarios y errores (verificado contra el conteo en App Store Connect).
- [ ] Las capturas siguen visibles días después (copia local).
- [ ] Puedo filtrar por app, fechas, build, dispositivo, SO, tester, estado y texto.
- [ ] CSV, Excel y PDF exportan exactamente lo que muestra la vista filtrada; el CSV abre en Excel con acentos correctos.
- [ ] El PDF incluye portada, resumen con gráficas, comentarios con miniatura y errores.
- [ ] Recibo una notificación de macOS cuando llega feedback nuevo durante una sincronización automática.
- [ ] La app funciona en sandbox, firmada y notarizada, en un Mac sin Xcode.

---

## 15. Limitaciones conocidas

- Apple solo entrega el feedback de testers con **iOS 13, visionOS 1.0, macOS 12 o versiones posteriores**.
- La API solo expone el feedback de **TestFlight**. Los crashes de producción y las reseñas públicas quedan fuera del MVP. Las reseñas podrían agregarse después con `GET /v1/apps/{id}/customerReviews`.
- La sincronización automática solo corre con la app abierta (ventana o barra de menús).
- La API key tiene acceso a todas las apps del equipo según su rol, así que conviene usar una key dedicada solo para esta herramienta.
- **Modo sesión:**
  - Usa la **API interna de la web** de App Store Connect, que no es pública ni está documentada. Apple puede cambiarla sin aviso; si eso pasa, habrá que ajustar `WebSessionTransport` y los mappers. El modo API key no se ve afectado.
  - La sesión expira cada cierto tiempo (días o semanas) y hay que volver a iniciar sesión con 2FA. Mientras tanto, la sincronización automática queda pausada.
  - El acceso automatizado a la web está en una zona gris de los términos de Apple. Se mitiga con uso de solo lectura, poco volumen (mínimo 1 h entre sincronizaciones) y solo datos a los que el usuario ya tiene acceso. Aun así, **se recomienda migrar al modo API key** cuando un Admin lo habilite; el cambio no requiere tocar nada más de la app.
