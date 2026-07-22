# Sofa — guía de mantenimiento

Documento de entrada para quien retome el proyecto sin contexto previo.
Léelo entero antes de tocar código: casi todas las decisiones raras que verás
tienen un motivo verificado, y varias se descubrieron rompiendo cosas.

**Este es el proyecto:** `/Users/pablo/Downloads/Sofa-Swift` (Swift nativo).
**No trabajar sobre `../Sofa`:** es la app Electron antigua (**Sofa Legacy**),
conservada solo por historia. El proyecto se reescribió de Electron a Swift
para bajar de ~239 MB a ~18 MB y 0 % de CPU en reposo (medido: 0,0 % sin sala,
~1,2 % sincronizando).

---

## 1. Qué es Sofa

App de barra de menús de macOS (`LSUIElement`, sin icono en el Dock) para ver
películas con amigos **en sincronía a distancia**. Cada persona reproduce su
propia copia o su propia cuenta de streaming; Sofa solo sincroniza el *estado*
de reproducción.

La idea central, y lo que la distingue: **Sofa no reproduce vídeo, controla el
reproductor que ya usas.** QuickTime, VLC, Apple TV, y cualquier vídeo HTML5 en
Safari o Chrome (YouTube, Netflix, Prime Video, Disney+). Si uno pausa, se pausa
en el Mac del otro; si uno retrocede 15 s, retroceden los dos.

Nunca viaja vídeo ni audio por la red: solo mensajes diminutos
(`play`, `pause`, `seek`, `tick`, `loaded`, `hello`, `bye`).

Funciones principales:

- **Watch parties online** por un relay propio (funciona entre casas y países).
- **Modo LAN** sin internet (servidor WebSocket local en el puerto `7420`).
- **Amigos guardados** con invitaciones directas dentro de la app.
- **Theater**: pantalla completa del vídeo dejando hueco a la videollamada.
- **Volumen independiente de FaceTime**, para que la llamada no tape la peli.
- **Test Zone**: un "amigo simulado" real para probar todo sin otra persona.

---

## 2. Mapa del código

Todo en `Sources/Sofa/` (~7 200 líneas). Por orden de importancia:

| Fichero | Líneas | Responsabilidad |
|---|---|---|
| `AppState.swift` | 1251 | **Empieza aquí.** Estado central `@MainActor` y orquestador: ciclo de vida de la sala (`hostRoom`, `join`, `leaveRoom`, `enterTestZone`), selección de reproductor, Theater, audio, roster de amigos. Casi toda acción de usuario pasa por aquí. |
| `SyncEngine.swift` | 1066 | Protocolo de sincronización. Relay LAN embebido (`NWListener`) + cliente (`NWConnection`), handshake con secreto, presencia + vigilancia de vida, difusión y aplicación de comandos. |
| `PlayerBridge.swift` | 1138 | Puente AppleScript a los reproductores externos. Sondeo (~0,85 s), detección de cambios locales, aplicación de comandos remotos, inyección de JS en navegadores. |
| `WindowArranger.swift` | 1149 | Theater: composición verificada y reversible de ventanas. La parte más delicada del proyecto. |
| `Views.swift` | 1201 | Toda la UI SwiftUI: panel, tour de bienvenida, tarjetas de sala/reproductor/audio/Theater, invitaciones. |
| `SocialService.swift` | 434 | Amigos guardados e invitaciones vía `/v1/social/...`. Identidad de dispositivo en el llavero. |
| `App.swift` | 353 | `AppDelegate`: item de barra de menús, panel `NSPanel`, enlaces `sofa://`, menú Edit (⌘V), auto-ajuste de altura del panel. |
| `CallAudioVolume.swift` | 385 | Tap de Core Audio para atenuar solo el audio de FaceTime. |
| `Updater.swift` | 292 | Check for Updates contra GitHub Releases + sustitución segura del bundle. |
| `FakeCall.swift` | 153 | Ventana de videollamada falsa para probar Theater sin llamar a nadie. |
| `TestFriend.swift` | 149 | Amigo simulado: **peer real** que se une a la sala real por WebSocket. |
| `RoomTarget.swift` | 119 | Parser de invitaciones (`sofa://join/v1/<room>/<secret>`, https `/j/`, código suelto y LAN). |
| `MediaSourceDetector.swift` | 42 | Qué reproductores están abiertos (solo `NSWorkspace`, sin permisos). |
| `SystemVolume.swift` | 39 | Volumen del sistema vía `osascript`, con anti-rebote. |

Fuera de `Sources/`:

- `Relay/` — backend Cloudflare Worker (TypeScript) + su suite de tests.
- `BrowserExtension/` — helper de Theater para navegadores. **Va embebido dentro
  de `Sofa.app`**; los usuarios no instalan nada aparte.
- `Tests/` — harnesses ejecutables sueltos (no XCTest; ver §7).
- `scripts/`, `Design/` — utilidades de verificación y generación de iconos.
- `Resources/` — iconos, vídeo de prueba, bundle de Icon Composer.

Configuración en `Info.plist`: `SofaRelayURL`, `SofaUpdateRepo`,
`CFBundleIdentifier` = `com.pablo.sofa.native`, mínimo macOS 14.

---

## 3. Cómo funciona la sincronización

Un mensaje es JSON plano: `{type, time, playing, name, art, token, from, sentAt}`.
El formato es idéntico al de la app Electron original, por compatibilidad
histórica.

**Sala online** (por defecto):

1. `POST /v1/rooms` al relay → devuelve `roomID`, `secret`, URL WSS e
   `inviteURL` (`sofa://join/v1/<roomID>/<secret>`).
2. Ambos Macs abren una conexión **saliente** WSS al relay. Por eso funciona
   sin abrir puertos ni configurar routers.
3. El primer mensaje debe ser `hello` con el `secret`; si no, el relay corta.

**Sala LAN / Test Zone:** un Mac hace de servidor en el puerto `7420`. No
depende de Cloudflare.

**El bucle de sincronización** (`PlayerBridge`): cada ~0,85 s pregunta al
reproductor su posición y estado; si detecta un cambio que no provocó un
comando remoto, lo difunde. Al recibir un comando remoto lo aplica con
compensación de latencia (corregida de desfase de reloj con una línea base
mínima por conexión, `latencyBaselineMs`) y activa una ventana de supresión
para no crear un eco infinito. La supresión es **semántica**, no ciega: guarda
el estado que el comando remoto debe producir (`expectedPlayingAfterRemote`) y
se re-ancla cuando el comando termina de ejecutarse
(`markRemoteCommandSettled`); una acción del usuario que contradiga al comando
ya asentado se difunde igualmente. Cada 5 s se manda un `tick` de estado
**también en pausa** (lleva `playing`): un receptor que sigue reproduciendo
cuando el emisor está pausado repara así una pausa perdida (converge siempre
hacia pausa, la dirección segura). Un `tick` que no corrige nada no toca la
supresión ni la línea base de detección.

---

## 4. Trampas conocidas (esto es lo que te ahorrará horas)

Cada punto se descubrió con un fallo real. No "simplificar" ninguno sin
reproducir antes el problema.

**AppleScript relanza apps cerradas.** `tell application "Safari"` **arranca**
Safari si no está abierto. Con un sondeo cada 0,85 s, esto resucitaba la app
cada vez que el usuario la cerraba. Siempre comprobar `PlayerChoice.isRunning`
(que usa `NSRunningApplication`) **antes** de cualquier AppleScript.

**La supresión ciega se tragaba pausas (la gran causa del "no es fiable",
0.1.63).** Hasta 0.1.62, *cualquier* mensaje recibido — incluido cada `tick`
de cada amigo, cada ~5 s — abría 2 s de ceguera (`suppressUntil` +
`lastState = nil`) en la que la línea base se sobrescribía sin comparar: una
pausa local en esa ventana **no se difundía jamás** (en salas de 3 la ceguera
cubría la mayoría del tiempo). Encima la pausa era un mensaje único sin
reparación (los ticks solo se emitían/aplicaban reproduciendo), así que una
pausa perdida = amigos 20-30 s por delante. No volver a suprimir a ciegas: ver
`expectedPlayingAfterRemote`, `markRemoteCommandSettled`, ticks de estado en
pausa y la reparación en `applyRemote("tick")`.

**Un frame puede adelantar al hello del handshake y envenenar la reconexión.**
`NWConnection` encola envíos antes de `.ready`; un `tick` del sondeo encolado
en una reconexión llegaba al relay **antes** del hello con token y el relay
cerraba con 1008 "hello required", en bucle. `sendRaw` descarta todo lo que no
sea el hello con token mientras `awaitingWelcome != nil`. No quitar esa guarda.

**App Nap estrangulaba los timers justo durante la peli.** Sofa es un app de
barra de menús sin ventana visible mientras se ve el vídeo: candidata ideal a
App Nap, que espacia los timers (sondeo, ticks, presencia) y deja la sala a la
deriva. En sala se mantiene `ProcessInfo.beginActivity([.userInitiated,
.latencyCritical])` (`roomActivity` en `AppState`); se libera en `leaveRoom`.

**Sockets zombi: TCP no avisa en minutos.** Tras una siesta del Mac o un
cambio de Wi-Fi, los envíos caen en un socket medio muerto y el usuario cree
que sincroniza. Defensas en capas (0.1.63): keepalive TCP (15 s/5 s/×3),
`viabilityUpdateHandler` con plazo de 12 s, y un vigilante aplicativo en el
timer de presencia (con amigos en sala online, >25 s sin frames de peers =
enlace muerto → escalera de reconexión). Tras el `welcome` de una reconexión
se re-anuncia el estado (`broadcastCurrentMedia` + `seek`) porque todo lo
"enviado" durante la caída se perdió. Los comandos con antigüedad corregida
>15 s se descartan (un socket zombi los soltaba en ráfaga al morir).

**El relay reasigna `from` en cada reconexión.** El peerID es aleatorio por
socket: el mismo amigo reaparece con otra identidad, y su entrada vieja
acababa podada a los 31 s con auto-pausa fantasma para toda la sala.
`upsertFriend` pliega en silencio la entrada antigua con el mismo nombre.

**URLs iguales no significan contenido igual (y al revés).** Fuera de
Netflix/YouTube, `location.href` lleva tracking por usuario (query strings,
`/ref=…` de Amazon): dos personas viendo lo mismo tenían URLs distintas y el
guard `sameContent` descartaba **en silencio** todos los comandos entre ellas.
Comparar con `PlayerBridge.contentKey` (host+path tolerante) con reserva a
título igual (`SyncEngine.contentMatches`), y avisar con toast (throttled)
cuando de verdad se descarta. Nunca descartar en silencio.

**WebSocket con `NWConnection` exige endpoint URL.** Con `.hostPort` el
handshake HTTP sale malformado y la conexión aborta con POSIX 53. Hay que usar
`.url(ws://…)`. Coste: horas de depuración.

**`pipefail` + `grep -q` = falso negativo.** En los scripts, `cmd | grep -q X`
falla aunque encuentre la coincidencia: `grep` cierra la tubería, `cmd` recibe
SIGPIPE y `pipefail` lo reporta como error. Capturar en variable primero
(`OUT=$(cmd || true); echo "$OUT" | grep -q X`). Esto rompió `build.sh` en
silencio, dejando la app firmada ad-hoc sin avisar.

**`@State` de SwiftUI no compila con las Command Line Tools.** El plugin de
macros vive solo dentro de Xcode. Por eso `RemoteImage` está hecho con AppKit
(`NSViewRepresentable`) en vez de `@State`. Si necesitas estado local en una
vista, usa `@ObservedObject` sobre un modelo, o AppKit.

**macOS fija el borde superior de las ventanas.** No se puede subir una ventana
por encima de la barra de menús para recortar el cromo del navegador: el gestor
de ventanas la devuelve (pedí y=-80, quedó en y=33).

**La pantalla completa nativa no deja hueco al lado.** Es una restricción dura
del sistema: una ventana en fullscreen ocupa un Space entero. Por eso Theater
**no** usa fullscreen nativo para el caso general, sino ventana maximizada +
telón negro + inyección de CSS que hace que el vídeo llene la ventana. Y si el
usuario ya estaba en fullscreen nativo, Theater debe sacarlo primero (si no, el
vídeo se queda en su Space y solo se ve el telón negro vacío).

**Cambiar la identidad de firma resetea los permisos TCC.** macOS identifica la
app por su *designated requirement*; al cambiar de firma, pierde Accesibilidad y
Automatización y los vuelve a pedir. Avisarlo siempre en las notas de release.

**Banners de notificación: RESUELTO (2026-07-21), pero conoce la trampa.**
Durante meses `UNUserNotificationCenter` devolvió `UNErrorDomain Code=1
"Notifications are not allowed"` incluso notarizada. Diagnóstico final con
`/usr/bin/log` (ojo: `log` a secas es un builtin de zsh que se traga la
salida): `usernoted` guardaba un registro para `com.pablo.sofa.native` con
`authorizationStatus: Denied` pero todos los sub-ajustes Enabled — una
denegación fantasma heredada de la era autofirmada/beta, invisible en
Ajustes porque la app no estaba en la lista de `com.apple.ncprefs`
(`defaults export com.apple.ncprefs -`). El almacén real (`~/Library/Group
Containers/group.com.apple.usernoted/db2/db`) está protegido por TCC y no se
puede editar sin Full Disk Access.

**El arreglo:** añadir a `com.apple.ncprefs` una entrada para la app clonando
los valores de una app de terceros que funcione (se usó WhatsApp: `auth: 47`,
`flags: 278929422`, `content_visibility: 0`, `grouping: 0`, `path`), importar
con `defaults import` y `killall cfprefsd usernoted usernotificationsd`.
Tras eso: `authorizationStatus=2 (Authorized)`, banners entregándose.
Si un amigo que usó versiones autofirmadas viejas sufre lo mismo, este es el
remedio. La app sigue reintentando `requestAuthorization` en cada arranque, y
el aviso dentro de la app (panel + `PartyInvitationCard` + sonido) se mantiene
como respaldo. Sonda de diagnóstico: `SOFA_NOTIFY_TEST=1
/Applications/Sofa.app/Contents/MacOS/Sofa` (modo dev en `main.swift`).

**El helper de Theater tiene versión acoplada.** `PlayerBridge.swift` y
`BrowserExtension/content.js` comparten un marcador (`0.1.30-efficiency`) que
usan para saber si el helper inyectado está al día. **Si cambias el helper,
cambia el marcador en los dos sitios**; si no, o no se actualiza o se reinyecta
en bucle. No tiene que coincidir con la versión de la app.

---

## 5. Firma y notarización

Firma oficial desde 0.1.34: **`Developer ID Application: Pablo Jimenez
(SX87SFWP3N)`** (llavero de login), con hardened runtime y el entitlement de
Apple Events (`Sofa.entitlements`). **Sin ese entitlement, el hardened runtime
bloquea todo AppleScript y Sofa deja de sincronizar.**

`build.sh` detecta el Developer ID y lo usa solo. `package-release.sh` notariza
(`xcrun notarytool submit --keychain-profile "Sofa" --wait`) y grapa el ticket.
Las credenciales están en el llavero bajo el perfil `Sofa`; recrear con
`xcrun notarytool store-credentials` (necesita una contraseña específica de app
de appleid.apple.com — **nunca escribirla en logs, docs ni Git**).

Notas:

- El DMG **no** se grapa: el ticket pertenece a la app. Intentarlo da
  "Record not found". Gatekeeper valida la app al abrirla, que es lo que cuenta.
- Si el llavero está bloqueado (sesión cerrada), `notarytool` falla con
  "No Keychain password item found". No es que falte la credencial.
- Identidad antigua `Sofa Self-Signed` sigue como fallback.
  `SOFA_SIGNING=self-signed ./build.sh` la fuerza (se usó para la 0.1.33).
- Verificar como lo haría un usuario:
  `xattr -w com.apple.quarantine "0081;0;Safari;" dist/Sofa.app && spctl -a -vv --type execute dist/Sofa.app`
  → debe decir `source=Notarized Developer ID`.

### Migración de confianza del actualizador (importante)

Los updaters ≤ 0.1.32 solo aceptaban una actualización **con firma idéntica** a
la instalada. Publicar directamente con la firma nueva habría dejado a esos
usuarios sin poder actualizarse nunca.

Solución: la **0.1.33 es un puente** — firmada con la identidad *antigua* (para
que los updaters viejos la acepten) pero conteniendo ya la regla nueva
`Updater.isAcceptableRequirement`, que acepta el salto único a Developer ID del
equipo `SX87SFWP3N` con el mismo bundle ID. Nunca a la inversa: no hay downgrade
de Developer ID a autofirmada, ni salto a otro equipo u otro bundle.

Ruta de actualización de un usuario antiguo: **0.1.32 → 0.1.33 → 0.1.34+**.

La regla está duplicada en `Tests/UpdaterTrustHarness/TrustRule.swift` porque el
harness no puede enlazar el target de la app. `scripts/check-trust-rule.sh`
falla si las dos copias divergen y ejecuta los 7 casos. **Correr en cada
release.**

---

## 6. Backend: el relay de Cloudflare

Código en `Relay/`. Es un Worker con dos Durable Objects SQLite:

- `Room` (`src/room.ts`) — salas efímeras; TTL por defecto 24 h
  (`DEFAULT_ROOM_TTL_SECONDS` en `src/config.ts`, configurable por entorno y
  acotado entre 60 s y 7 días).
- `SocialHub` (`src/social.ts`) — amigos, presencia e invitaciones.
- `src/protocol.ts` — validación y saneado de mensajes (lista blanca de tipos,
  límite de tamaño, rate limiting).

Desplegar:

```bash
cd Relay
npm install
npm run typecheck
npm test
npx wrangler login      # solo la primera vez
npm run deploy
npm run smoke -- https://sofa-sync-relay.pablopjc.workers.dev
```

Si Cloudflare da otro host, actualizar `SofaRelayURL` en `Info.plist` y publicar
app nueva. **No** configurar a la vez `exports` y migraciones legacy de Durable
Objects: `wrangler.jsonc` usa `exports`.

**Identidad social:** se guarda en el llavero (servicio
`com.pablo.sofa.native.social`, cuenta `device-credential`). Nunca imprimirla ni
commitearla. **Un fallo de red al pedir `/me` no es una credencial inválida** —
solo borrar la clave ante un rechazo de autenticación inequívoco; si no, macOS
pide acceso al llavero en bucle y el usuario pierde su identidad social.

---

## 7. Pruebas

No hay XCTest. Los tests son harnesses ejecutables y suites del relay:

```bash
# Regla de confianza del actualizador (7 casos) + detección de divergencia
./scripts/check-trust-rule.sh

# Parser de invitaciones (14 casos)
swiftc -o /tmp/rt Tests/RoomTargetHarness/main.swift Sources/Sofa/RoomTarget.swift && /tmp/rt

# WebSocket nativo contra el relay real de producción
swiftc -o /tmp/nw Tests/NWWebSocketHarness/main.swift && /tmp/nw https://sofa-sync-relay.pablopjc.workers.dev

# Relay (18 tests) + typecheck
cd Relay && npm run typecheck && npm test
```

**Prueba end-to-end real** (lo más valioso, y no está automatizada). Crear una
sala por API, abrir el enlace para que la app se una, conectar una sonda como
"amigo remoto" y comprobar que los comandos llegan en ambos sentidos:

```bash
curl -sS -X POST "https://sofa-sync-relay.pablopjc.workers.dev/v1/rooms" \
  -H "Content-Type: application/json" \
  -H "X-Sofa-Client-ID: $(uuidgen | tr 'A-Z' 'a-z')" \
  -H "X-Sofa-Protocol: 1" -d '{}'
# → abrir el inviteURL con `open`, y conectar por WSS con un cliente ws de Node
```

El `X-Sofa-Client-ID` debe ser un UUID v4 válido o el relay responde 400.

**Probar en Intel:** `open --arch x86_64 /Applications/Sofa.app`. Lanzar el
binario suelto no vale: los enlaces `sofa://` no le llegan porque no pasa por
LaunchServices.

---

## 8. Publicar una versión

`Check for Updates…` lee `https://api.github.com/repos/Pablopjc/sofa/releases/latest`
(configurado en `Info.plist` → `SofaUpdateRepo`). El repo y la release deben ser
**públicos**; una draft no llega al actualizador.

Flujo obligatorio:

1. **Subir versión** en `Info.plist` (los dos campos, iguales) y en
   `BrowserExtension/manifest.json`. Incremento de `0.0.1`: tras `0.1.34` va
   `0.1.35`. Si cambia el helper Theater, actualizar su marcador en
   `content.js` **y** `PlayerBridge.swift` (§4).
2. **Verificar**:

   ```bash
   swift build
   ./scripts/check-trust-rule.sh
   cd Relay && npm run typecheck && npm test
   ```

3. `git diff --check`, commit y `git push origin master`.
4. Publicar **solo con el script** (nunca una release manual):

   ```bash
   ./release.sh 0.1.35 "Notas breves"
   ```

`release.sh` exige árbol limpio, rama `master` idéntica a `origin/master`, y
que `Info.plist` ya tenga la versión pedida. Luego compila, firma, notariza,
crea DMG (para enviar a amigos) y ZIP (para el actualizador), verifica versión,
ambas arquitecturas, firma y DMG, sube una **draft**, la vuelve a descargar,
compara **byte a byte**, y solo entonces la marca como `latest`.

Guardar copia de recuperación en `/Users/pablo/Downloads/Sofa-Stable/<versión>/`.

**Si GitHub falla a mitad** (pasó con 502/503 en la 0.1.33): la release queda en
draft sin assets. Recuperar con `gh release upload <tag> <ficheros> --clobber`,
verificar bytes y `gh release edit <tag> --draft=false --latest`.

---

## 9. Comprobaciones rápidas

```bash
./build.sh
lipo -archs dist/Sofa.app/Contents/MacOS/Sofa      # debe decir: x86_64 arm64
codesign --verify --deep --strict dist/Sofa.app
codesign -dvvv dist/Sofa.app 2>&1 | grep Authority # Developer ID en releases
./scripts/check-trust-rule.sh
node --check BrowserExtension/content.js
spctl -a -vv --type execute dist/Sofa.app          # "Notarized Developer ID"
```

Instalar en local para probar:

```bash
pkill -f "Sofa.app/Contents/MacOS/Sofa"; sleep 1
rm -rf /Applications/Sofa.app && ditto dist/Sofa.app /Applications/Sofa.app
open /Applications/Sofa.app
```

---

## 10. Decisiones tomadas (no rehacer sin motivo)

- **No Mac App Store.** El sandbox obligatorio rompería el mecanismo central
  (controlar reproductores ajenos por AppleScript). La vía Developer ID +
  notarización + descarga directa es la correcta y no limita usuarios.
- **No Sparkle** para actualizar: valida que la firma nueva coincida con la
  vieja, lo que impedía la migración de firma. El actualizador propio hace las
  mismas comprobaciones más la regla de migración.
- **Licencia MIT**, elegida por el autor. `LICENSE`, `README.md` y `PRIVACY.md`
  están escritos para público general, no para el autor.
- **Escala del relay:** el plan gratuito de Cloudflare basta para amigos y
  público moderado. Con tráfico masivo habría que pasar a plan de pago
  (excluido explícitamente por el autor).
