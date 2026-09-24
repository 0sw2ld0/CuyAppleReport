# CuyAppleReport

Aplicación nativa macOS para consultar y revisar feedback de TestFlight. Se conecta de dos formas: **iniciando sesión con tu Apple ID** (sin API key, con tus mismos permisos) o con una **API key `.p8`** de App Store Connect.

## Instalar

1. Abre `dist/CuyAppleReport-1.0.dmg` y arrastra **CuyAppleReport** a **Aplicaciones**.
2. La app está firmada *ad hoc* (sin Developer ID ni notarización). La primera vez, en otro Mac, ábrela con **clic derecho → Abrir** o desde **Ajustes del Sistema → Privacidad y seguridad → Abrir igualmente**.

## Usar

1. Abre CuyAppleReport (o `CuyAppleReport.xcodeproj` en Xcode y ejecuta el esquema `CuyAppleReport`).
2. En **Ajustes → Conexión** elige el modo:
   - **Iniciar sesión con Apple ID**: pulsa *Iniciar sesión con Apple*, entra con tu Apple ID y el código 2FA en la página de Apple y elige el **equipo**. La contraseña solo se escribe en la web de Apple; la app guarda únicamente la sesión web, aislada por conexión.
   - **API key (.p8)**: configura Issuer ID, Key ID y el archivo `.p8`.
3. Pulsa **Probar conexión**, selecciona las apps y guarda la conexión.
4. Pulsa **Sincronizar** en la ventana o usa `⌘R`.

La clave privada se guarda en Keychain. En modo Apple ID, cuando la sesión caduca la app avisa con una notificación, pausa la sincronización y muestra el botón **Iniciar sesión**; el mínimo de sincronización automática en ese modo es 1 hora. El feedback, las capturas descargadas y los logs quedan en el almacenamiento local de la app. El proyecto también puede regenerarse desde `project.yml` con XcodeGen (`xcodegen generate`).

## Alcance implementado

- Modo **Iniciar sesión con Apple ID**: login en la web real de Apple (`WKWebView`), selección de equipo, peticiones a la API interna de la web (`/iris/v1`) con la sesión, aviso de sesión expirada.
- Modo **API key**: configuración con validación y drop/import de `.p8`, prueba de conexión y selección de apps.
- JWT ES256, Keychain, SwiftData y cliente paginado de App Store Connect.
- Sincronización manual e incremental y periódica mientras la app siga abierta en ventana o barra de menús; notificaciones y resumen de barra de menús.
- Dashboard, tabla/galería, búsqueda, filtros de fecha, build, tester, SO, dispositivo y estado; inspector con notas y seguimiento.
- Exportación de la vista actual a CSV UTF-8 con BOM, Excel `.xlsx` multihoja y un informe PDF con portada, resumen con gráficos, comentarios con capturas y errores.

## Requisitos

- macOS 14 o posterior y Xcode 16 o posterior.
- Un Apple ID con acceso al feedback de TestFlight en App Store Connect, o una API key con un rol que lo permita.
- El modo Apple ID usa la API interna de la web de App Store Connect, que no es pública: Apple puede cambiarla sin aviso. El modo API key no se ve afectado.

## Desarrollo

```bash
xcodegen generate          # regenera CuyAppleReport.xcodeproj desde project.yml
open CuyAppleReport.xcodeproj
```

En compilaciones **Debug** existe un modo demo que no toca datos reales (base de datos en memoria y feedback de ejemplo):

```bash
CuyAppleReport.app/Contents/MacOS/CuyAppleReport --sync-demo                # sincronización simulada
CuyAppleReport.app/Contents/MacOS/CuyAppleReport --sync-demo --export-pdf   # genera un PDF de ejemplo
```

`fixtures/iris/` contiene respuestas anonimizadas de App Store Connect para pruebas. `CuyAppleReport.md` es la especificación funcional.

## Generar el instalador

```bash
./scripts/build-installer.sh
```

Compila Release desde cero, firma la app *ad hoc* solo con sus entitlements (sin `get-task-allow`) y crea `dist/CuyAppleReport-<versión>.dmg`. En git solo se versiona ese `.dmg`; el resto de `dist/` se ignora. Para distribuir fuera del equipo conviene firmar con Developer ID y notarizar.
