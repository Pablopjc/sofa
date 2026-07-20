# Sofa — notas de mantenimiento

Este es el proyecto nativo actual: `/Users/pablo/Downloads/Sofa-Swift`.
No trabajar sobre `../Sofa`: es la aplicación Electron antigua (**Sofa Legacy**).

## Estado y versiones

- La versión publicada actual está en `Info.plist` (`CFBundleShortVersionString` y `CFBundleVersion`). Ambas deben ser iguales.
- Cada cambio publicado incrementa el último número: después de `0.1.30`, usar `0.1.31`.
- El binario debe seguir siendo universal: `arm64` y `x86_64`.
- Las copias de recuperación publicadas se guardan fuera del repositorio en `/Users/pablo/Downloads/Sofa-Stable/<versión>/`.

## Firma y notarización

Desde la 0.1.34, la firma oficial es el certificado de Apple
**`Developer ID Application: Pablo Jimenez (SX87SFWP3N)`** (en el llavero de
login), con hardened runtime y el entitlement de Apple Events
(`Sofa.entitlements` — sin él, todo el control AppleScript de reproductores
dejaría de funcionar). `build.sh` lo detecta y lo usa automáticamente;
`package-release.sh` notariza (`xcrun notarytool submit --keychain-profile
"Sofa" --wait`) y grapa el ticket en la app. Las credenciales de notarización
están guardadas en el llavero bajo el perfil `Sofa` (recrear con
`xcrun notarytool store-credentials`). El DMG no se grapa: el ticket pertenece
a la app, y Gatekeeper comprueba la app al abrirla.

- La identidad antigua `Sofa Self-Signed` sigue en el llavero como fallback si
  el Developer ID desapareciera. `SOFA_SIGNING=self-signed ./build.sh` fuerza
  su uso.
- **Migración de confianza del actualizador**: los updaters ≤ 0.1.32 solo
  aceptan una actualización con firma idéntica a la instalada. Por eso la
  0.1.33 (puente) se publicó firmada con `Sofa Self-Signed` pero con la regla
  nueva (`Updater.isAcceptableRequirement`), que además de la igualdad acepta
  el salto único a Developer ID del equipo `SX87SFWP3N` con el mismo bundle ID
  (nunca a la inversa: no hay downgrade de Developer ID a autofirmada). La ruta
  de actualización de un amigo antiguo es 0.1.32 → 0.1.33 → 0.1.34+.
- La regla vive duplicada en `Tests/UpdaterTrustHarness/TrustRule.swift`;
  `scripts/check-trust-rule.sh` falla si las dos copias divergen y ejecuta el
  harness. Correr en cada release.
- Al cambiar la identidad de firma, macOS pierde los permisos TCC concedidos
  (Accesibilidad, Automatización); los usuarios los verán pedirse de nuevo una
  vez. Avisarlo en las notas de la release.
- **Notificaciones**: ni siquiera la app notarizada consigue banners en este
  Mac (macOS 27 beta devuelve `UNErrorDomain Code=1`); posiblemente membresía
  aún propagándose o comportamiento de la beta. La app repite
  `requestAuthorization` al arrancar y al llegar cada invitación, de modo que
  si Apple empieza a permitirlo, se activa solo.

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

**Notificaciones del sistema (banners):** ver la sección «Firma y notarización» — incluso notarizada, la app no consigue banners en macOS 27 beta. La invitación llega igual **dentro de la app**: al recibir `party_invite`, `SocialService.handle` la añade, abre el panel (`.sofaShowPanel`), muestra `PartyInvitationCard` ("X invited you") y suena un aviso.

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

El actualizador descarga el ZIP, no el DMG. Antes de sustituir la app comprueba el bundle ID, la versión, la firma y la requirement de firma según `Updater.isAcceptableRequirement` (igualdad, o el salto único autofirmada→Developer ID del equipo propio; ver «Firma y notarización»). Nunca subir una app firmada con una identidad fuera de esas dos.

## Comprobaciones rápidas

```bash
./build.sh
lipo -archs dist/Sofa.app/Contents/MacOS/Sofa
codesign --verify --deep --strict dist/Sofa.app
./scripts/check-trust-rule.sh
node --check BrowserExtension/content.js
spctl -a -vv --type execute dist/Sofa.app   # "Notarized Developer ID" en releases
```

El helper Theater está incluido dentro de `Sofa.app`; no es necesario enviar una extensión separada a los usuarios.
