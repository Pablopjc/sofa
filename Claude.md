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

### Theater: the player is not always inside what the site fullscreens

Movistar Plus+ (0.1.78) fullscreens `document.documentElement` and hangs the
real player off `<body>` as a `position: fixed` overlay (`z-index: 999999`).
`findGenericTarget`'s walk — outermost normal-flow descendant of the fullscreen
element containing the video — therefore returns `<body>`, which is only as tall
as the page hidden behind the overlay (269px of a 949px viewport). installLayout
measured it, saw it did not cover, and reverted: Theater never opened, with no
visible error.

The fallback only fires when the usual answer fails `fillsViewport`, so the
services that already work never reach it (Prime's `.f1prfwap`, Disney's
`.btm-media-clients` and HBO's bare `<video>` are all `0,0 1512x949`). When it
does fire it takes the outermost ancestor of the video that fills the viewport —
the fixed overlay — and narrowing that works because a fixed element's
containing block IS the viewport.

`fillsViewport` deliberately tests height and left, never width: the
MutationObserver re-runs the target hunt while Theater is active and the target
is already narrowed, so a width test would flip the answer mid-session.

### Ad detection: prefer the class that describes the state, not the situation

Two services shipped a near-miss signal next to the real one. Prime's
`.atvwebplayersdk-ad-resume-message` literally reads "Your video continues here
after the break" and stays `visibility: hidden` through the entire break —
useless. Disney's `has-interstitials` appears next to `interstitial-ad-playing`
and sounds like a permanent "this title has ads" marker; it is not (it cleared
when the break ended), but nothing measured says what it does track.

Both were excluded for the same reason: only trust a signal whose positive AND
negative state you have watched flip on a real break. Guessing costs a friend's
film stopping for nothing.


## 4. Trampas conocidas (esto es lo que te ahorrará horas)

Cada punto se descubrió con un fallo real. No "simplificar" ninguno sin
reproducir antes el problema.

**Cerrar el panel "al perder el foco" hace que el icono parezca muerto
(0.1.81).** Pulsar un icono de la barra de menús **no activa** su app, así que
el `NSApp.activate(ignoringOtherApps:)` de `showPanel` compite con la gestión
de foco del sistema y macOS a veces se lo devuelve a la app anterior. El panel
se abría bien y `didResignKey` llegaba acto seguido *sin que nadie hubiera
pulsado nada*, cerrándolo: para el usuario, "pulso el icono y no pasa nada".
Instrumentar con `NSLog` fue lo único que lo demostró; para verlo, muestrear el
número de ventanas cada 30 ms (`1111100000…` = se abrió y se cerró sola). El
cierre cuelga ahora de un `addGlobalMonitorForEvents` de mouse-down: sin clic
no hay cierre. Los monitores globales solo ven eventos de **otras** apps, así
que ni el propio panel ni el status item los disparan, y los de ratón **no**
requieren permiso de Accesibilidad (los de teclado sí). Excepción real: la
paleta de emojis del sistema es otro proceso, pero escribe en un campo *dentro*
del panel — un clic ahí dispara el monitor **y** además hace que el panel
pierda `key`, así que ninguna señal por separado la distingue;
`EmojiPickerButton` publica `.sofaSuspendAutoHide` antes de abrirla.

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

**El helper de Theater tiene versión acoplada, y ya no se escribe dos veces.**
El marcador (`VERSION`, hoy `0.1.71-generic`) vive **solo** en
`BrowserExtension/content.js`; `PlayerBridge.theaterHelperVersion` lo lee de ahí
con una regex (`VERSION\s*=\s*"…"`) y el nombre del evento se deriva de él en los
dos lados. Al cambiar el helper basta con subir esa constante. Cuidado con
romper la regex: si deja de casar, Sofa despacha un evento que nadie escucha y
**Theater muere en todos los sitios a la vez, en silencio** (así se rompió
0.1.69). No tiene que coincidir con la versión de la app.

**El mismo predicado escrito dos veces es el fallo recurrente de Theater.**
0.1.69 hizo Theater genérico (cualquier servicio, no solo los tres enseñados)
pero solo actualizó una de las dos copias de "¿la página está en un fullscreen
que contiene al reproductor?": la del sondeo. La otra —la que decide si el botón
Theater se enciende y si el clic procede— conservó la lista blanca de
youtube/netflix/disneyplus, así que en **HBO Max** Sofa insistía en "pon el vídeo
en pantalla completa" por mucho que ya lo estuviera (arreglado en 0.1.71). Ahora
hay una sola `pageFullscreenTargetJS` (`function sofaFSTarget()`) que usan tanto
`browserGetJS` como `compatiblePageFullscreenJS`. Si añades una tercera pregunta
sobre fullscreen, reutilízala; no la copies.

**Cortes publicitarios (0.1.74).** Cuando a alguien le salen anuncios, su reloj
deja de ser el de la película. Antes esto se resolvía devolviendo `'none'` en
YouTube — y `'none'` significa "aquí no hay nada", lo que reportaba
`fullscreen:false` y **cerraba Theater en cada anuncio**. Ahora el sondeo
informa del anuncio (`ad`, un bitfield) y es Swift quien decide qué retener.
Tres reglas que no son negociables, cada una pagada con un fallo concreto del
análisis adversarial:
1. **Dos banderas, no una.** `rawAdSince` protege desde la PRIMERA muestra (no
   emitir, no aplicar comandos entrantes); `adBroadcast` anuncia con retardo y
   un suelo de 8 s. Si la protección esperase al retardo, el tick de un amigo
   pausaría el anuncio — y **un pre-roll pausado no termina nunca**, así que la
   sala quedaba muerta.
2. **El fin del corte se emite siempre.** La versión que solo reanudaba "si
   ningún otro está en anuncios" dejaba la sala pausada para siempre cuando dos
   mid-rolls se solapaban, que es el caso normal. Quien siga en su corte
   descarta la trama él mismo.
3. **Nunca se reanuda solo por timeout.** A los 20 s sin señal el aviso pasa a
   "terminó o se cayó" y el vídeo sigue pausado: el amigo puede estar en un
   corte largo no saltable.
El campo `ad` va **solo si el otro extremo dice que lo entiende** (`welcome`):
el relay valida con lista blanca de campos y responde `close(1008)` a lo
desconocido, así que mandarlo a un Worker sin actualizar tiraría el socket en
cada anuncio — y una desconexión pausa la película del propio anunciado.

**Una página puede tener varios reproductores reales a la vez (Prime Video).**
En `primevideo.com` la ficha del título mantiene vivo un preview silenciado
*detrás* del reproductor a pantalla completa — tres `<video>`, los tres con el
mismo `id` (`ATVWebPlayerHLSVideoSurface`), así que `document.querySelector('#…')`
devuelve el equivocado (cuidado al diagnosticar: acota siempre a
`fullscreenElement.querySelector('video')`). Peor: si ese preview se reproduce
mientras la película está pausada, gana la heurística de `vscore` (+1e12 por
estar reproduciendo) y Sofa emitía el reloj del tráiler — medido: `time 24.7,
playing false` → `time 0, playing true`, que arrastra a toda la sala al 0:00.
Desde 0.1.72 `bv()` restringe el conjunto a los `<video>` que hay **dentro del
elemento en fullscreen** cuando existe alguno: si la página está en pantalla
completa, lo que el espectador ve está ahí dentro y punto. Va después de las
ramas de Netflix y YouTube, que retornan antes, así que no puede cambiar lo que
eligen esas dos. Theater en Prime Video no necesitó nada: entra por el camino
genérico.

**Reproductores cuyo `<video>` cuelga directo del elemento en fullscreen**
(HBO Max) necesitan dos reglas de anchura —el vídeo y sus hermanos, vía
`data-sofa-theater-generic-box`— y gana la segunda por orden. Por eso
`content.js` recoge **todas** las reglas con `calc()` (`findSizingRules`) en vez
de la primera: con una sola, el tirador movía la costura y la imagen no se movía.
Y el tirador (la píldora gris) no puede dibujarse con `::after` sobre el elemento
dimensionado cuando ese elemento es el `<video>`: un elemento reemplazado no
genera contenido. Se dibuja sobre el contenedor, anclado a la costura con el
mismo `calc()`.

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
   `0.1.35`. Si cambia el helper Theater, subir `VERSION` en `content.js` —
   solo ahí; Swift la lee de ese archivo (§4).
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

Diagnóstico a distancia (0.1.83): Sofa registra eventos (arranques, panel,
Theater, permisos, toasts, cuelgues del hilo principal, desconexiones del
relay) en `~/Library/Logs/Sofa/Sofa.log` (rota a 512 KB, guarda una
generación). El menú ⋯ → "Save Diagnostic Report" escribe en el Escritorio un
informe completo: versión/ruta/firma, translocación, copias duplicadas (con
consejo keep/delete), estado de todos los permisos, estado de la app,
alcanzabilidad del relay y la cola del log. Headless para soporte:

```bash
SOFA_DIAG_REPORT=1 /Applications/Sofa.app/Contents/MacOS/Sofa   # escribe en el Escritorio y sale
```

Medir consumo (0.1.84): `scripts/measure-sofa.sh [minutos]` funciona con
CUALQUIER versión instalada, sin compilar y sin contraseña — muestrea y deja
informe + CSV en el Escritorio. Es lo que puede ejecutar un amigo con la
versión publicada antigua. Detalles que importan: el %CPU de `ps` es la media
DESDE EL ARRANQUE, no del intervalo — hay que restar tiempos de CPU
acumulados; `top -l 1` cuesta ~0,7 s de CPU por llamada (falsea la medida si
se usa en el bucle), así que solo se llama al principio y al final para los
idle wakeups; y bash no puede capturar SIGINT si el script se lanzó en
segundo plano (la señal se hereda ignorada), así que para probar el trap hay
que usar SIGTERM o un Terminal de verdad. El informe de diagnóstico incluye
además una sección `[Resources]` con CPU/memoria/wakeups leídos por
`proc_pid_rusage`. **TRAMPA**: `ri_user_time`/`ri_system_time` están en TICKS
de Mach, no en nanosegundos pese al nombre — hay que convertirlos con
`mach_timebase_info`. En Apple Silicon (125/3) tratarlos como ns subestima la
CPU ~42x; en Intel el timebase es 1:1 y el fallo es invisible. Verificado
quemando 2,00 s de CPU a propósito: 1,998 s bien convertido, 0,048 s sin
convertir. `phys_footprint` (lo que enseña Monitor de Actividad) es bastante
MENOR que el RSS que da `ps`: no se contradicen, miden cosas distintas.
Línea base medida en reposo sin fiesta: ~0,07% de CPU.

Flags dev: `SOFA_SIMULATE_AX_DENIED=1` simula Accesibilidad denegada (sin
tocar el TCC real ni quemar el prompt del sistema; el flag SofaAXPrompted pasa
a memoria). Trampas ya pagadas aquí: `UNUserNotificationCenter.current()`
aborta el proceso si el binario no corre desde un .app (guard en
`notificationStatus`); el watchdog usa Timer en `.common` (un `main.async` se
muere de hambre durante `runModal` → cuelgues falsos) y se suspende con
willSleep/didWake (el reloj de pared avanza durmiendo → cuelgues de 8 h
falsos); DiagLog escribe con `O_APPEND` (dos copias corriendo — justo el caso
que diagnostica — se pisarían con seek+write) y `DiagLog.flush()` va al final
de `applicationWillTerminate` (sin él, `exit()` descarta la línea
"terminate: clean quit" y todo quit parecería un crash).

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
