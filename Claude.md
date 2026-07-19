# Sofa — notas de mantenimiento

Este es el proyecto nativo actual: `/Users/pablo/Downloads/Sofa-Swift`.
No trabajar sobre `../Sofa`: es la aplicación Electron antigua (**Sofa Legacy**).

## Estado y versiones

- La versión publicada actual está en `Info.plist` (`CFBundleShortVersionString` y `CFBundleVersion`). Ambas deben ser iguales.
- Cada cambio publicado incrementa el último número: después de `0.1.30`, usar `0.1.31`.
- El binario debe seguir siendo universal: `arm64` y `x86_64`.
- La firma estable se llama `Sofa Self-Signed`. No sustituirla por firma ad-hoc: macOS perdería permisos de Automatización, Accesibilidad y acceso al llavero; además, el actualizador rechaza una app firmada con otra identidad.
- Las copias de recuperación publicadas se guardan fuera del repositorio en `/Users/pablo/Downloads/Sofa-Stable/<versión>/`.

## Sincronización online: Cloudflare

La sincronización online no transmite vídeo ni audio. Solo pasan mensajes pequeños de estado (`loaded`, `play`, `pause`, `seek`, `tick`, `hello`, `bye`) y presencia.

- El cliente Swift está en `Sources/Sofa/SyncEngine.swift`.
- La URL base se lee de `Info.plist` → `SofaRelayURL`:
  `https://sofa-sync-relay.pablopjc.workers.dev`
- `POST /v1/rooms` crea una sala online y devuelve un enlace `sofa://join/v1/<roomID>/<secret>` y una URL WSS.
- Los dos Macs se conectan saliendo por WSS al relay; por eso funciona aunque estén en redes/casas/países distintos.
- El modo LAN/Test Zone sigue usando el servidor WebSocket local en el puerto `7420`; no depende de Cloudflare.

El backend está en `Relay/`:

- `Relay/src/index.ts`: Worker y protocolo.
- `Relay/wrangler.jsonc`: configuración de Cloudflare.
- `Room`: Durable Object SQLite para salas efímeras.
- `SocialHub`: Durable Object SQLite para amigos, presencia e invitaciones.
- `ROOM_TTL_SECONDS` es `86400` (24 h).

Para cambiar y desplegar el relay:

```bash
cd Relay
npm install
npm run typecheck
npm test
npx wrangler login                 # solo la primera vez o al cambiar de cuenta
npm run deploy
npm run smoke -- https://sofa-sync-relay.pablopjc.workers.dev
```

Si Cloudflare publica un host distinto, actualizar `SofaRelayURL` en `Info.plist`, publicar una nueva app y comprobar el smoke test. No configurar simultáneamente `exports` y las migraciones legacy de Durable Objects: `wrangler.jsonc` usa `exports`.

## Amigos e invitaciones

`Sources/Sofa/SocialService.swift` usa el mismo Worker con rutas `/v1/social/...`.

- La identidad del dispositivo se guarda en el llavero de macOS como servicio `com.pablo.sofa.native.social` y cuenta `device-credential`.
- Nunca guardar ni imprimir ese token en logs, documentación o Git.
- No tratar un fallo temporal de red al pedir `/me` como una credencial inválida. Solo se debe borrar/reemplazar la clave ante una respuesta de autenticación inequívoca; de lo contrario macOS puede pedir repetidamente acceso al llavero y el usuario perdería su identidad social.

**Notificaciones del sistema (banners):** verificado en macOS 27 — `UNUserNotificationCenter` devuelve `UNErrorDomain Code=1 "Notifications are not allowed"` y la app ni se registra en el centro de notificaciones. Causa: macOS solo permite banners a apps notarizadas (identidad de Apple Developer); Sofa es autofirmada, y CLAUDE.md exige mantener esa firma. `NSUserNotification` (API antigua) tampoco entrega en macOS 26+. La invitación llega igual **dentro de la app**: al recibir `party_invite`, `SocialService.handle` la añade, abre el panel (`.sofaShowPanel`), muestra `PartyInvitationCard` ("X invited you") y suena un aviso. Se mantiene la llamada a `requestAuthorization`: si algún día se notariza, los banners se activan solos sin tocar código.

## Publicar una actualización que llegue desde la app

El menú **Check for Updates…** usa la API pública de GitHub:

```text
https://api.github.com/repos/Pablopjc/sofa/releases/latest
```

La configuración está en `Info.plist` → `SofaUpdateRepo` (`Pablopjc/sofa`). El repositorio y la release deben ser públicos; una release draft o privada no llega al actualizador.

Flujo obligatorio:

1. Incrementar versión en `Info.plist` (los dos campos) y en `BrowserExtension/manifest.json`. Si cambia el helper Theater, actualizar también sus marcadores de versión en `BrowserExtension/content.js` y `PlayerBridge.swift`.
2. Ejecutar al menos:

   ```bash
   swift build
   cd Relay && npm run typecheck && npm test
   ```

3. Revisar `git diff --check`, hacer commit y subir `master`:

   ```bash
   git add -A
   git commit -m "Describe the change"
   git push origin master
   ```

4. Desde la raíz del proyecto, publicar mediante el script; no crear una release manualmente:

   ```bash
   ./release.sh 0.1.31 "Short release notes"
   ```

`release.sh` exige un árbol limpio y `master` idéntico a `origin/master`. Después:

- Compila y firma `dist/Sofa.app`.
- Crea `Sofa-<versión>.dmg` para enviar a amigos.
- Crea `Sofa-<versión>-universal-mac.zip` para el actualizador integrado.
- Verifica versión, ambas arquitecturas, firma y DMG.
- Crea el tag `v<versión>`, sube una release draft, descarga de nuevo los artefactos y compara los bytes.
- Solo entonces publica la release como `latest`.

El actualizador descarga el ZIP, no el DMG. Antes de sustituir la app comprueba el bundle ID, la versión, la firma y que la requirement de firma coincida con la app instalada. Por eso nunca se debe subir una app firmada con otra identidad.

## Comprobaciones rápidas

```bash
./build.sh
lipo -archs dist/Sofa.app/Contents/MacOS/Sofa
codesign --verify --deep --strict dist/Sofa.app
node --check BrowserExtension/content.js
```

El helper Theater está incluido dentro de `Sofa.app`; no es necesario enviar una extensión separada a los usuarios.
