# Sofa Sync Relay

Cloudflare Worker de señalización efímera para sincronizar hasta ocho peers por sala. Cada sala es un Durable Object con almacenamiento SQLite y WebSocket Hibernation; no conserva el contenido de los eventos.

## API

### `GET /health` (o `/healthz`)

Devuelve `200 { "ok": true, "service": "sofa-sync-relay" }`.

### `POST /v1/rooms`

Crea una sala y devuelve `201`:

La app envía exactamente JSON `{}` junto con `X-Sofa-Protocol: 1` y un
identificador de instalación aleatorio en `X-Sofa-Client-ID`. Los headers
personalizados impiden que una web cualquiera dispare el POST como petición
simple; Cloudflare limita cada IP de origen a 12 creaciones por minuto.

```json
{
  "roomID": "AB3X7K",
  "secret": "secreto-base64url-de-256-bits",
  "webSocketURL": "wss://relay.example/v1/rooms/<roomID>",
  "inviteURL": "sofa://join/v1/<roomID>/<secret>",
  "expiresAt": 178... 
}
```

La respuesta lleva `Cache-Control: no-store`. El código visible usa seis caracteres del alfabeto inequívoco `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`; se comprueban colisiones y se reintenta con otro código. El código no es una credencial: la seguridad reside en el secreto de 256 bits. La app puede compartir directamente `inviteURL`.

### `GET /v1/rooms/:roomID`

Requiere `Upgrade: websocket`. El primer frame debe ser exactamente un mensaje de tipo `hello` que incluya el secreto:

```json
{ "type": "hello", "token": "..." }
```

El servidor responde con `welcome` y publica listas `peers`. Ambos tipos son exclusivamente servidor → cliente:

```json
{ "type": "welcome", "peerID": "...", "peers": ["..."], "expiresAt": 178... }
{ "type": "peers", "count": 2, "peers": ["...", "..."] }
```

El `hello` inicial se autentica con `token`, se sanea y se reenvía a los peers que ya estaban en la sala. Tras autenticarse, el cliente puede seguir enviando `hello` periódicos, además de `loaded`, `play`, `pause`, `seek`, `tick` y `bye`. El relay elimina recursivamente campos `token`, `secret` y `from`, redacta valores que contengan el secreto y añade el `from` asignado por el servidor. No hace eco al emisor.

## Límites y ciclo de vida

- 8 peers autenticados por sala y como máximo 16 conexiones pendientes.
- Frames de texto JSON de hasta 16 KiB; no se admiten frames binarios.
- 60 frames por peer cada 10 segundos. El estado del límite viaja en el attachment hibernable del WebSocket.
- 12 salas nuevas por IP y minuto; 60 intentos de conexión por sala/IP y minuto mediante bindings nativos de Cloudflare.
- `hello` debe llegar en 10 segundos.
- TTL por defecto de 24 horas. El Durable Object cierra sockets y borra su estado mediante una alarma. Se puede configurar `ROOM_TTL_SECONDS` entre 60 segundos y 7 días.
- Códigos visibles aleatorios de 6 caracteres, con detección de colisiones, y secretos aleatorios de 256 bits.

Los bindings de Rate Limiting se ejecutan antes de crear Durable Objects. El límite por frame implementado en la sala protege además el tráfico WebSocket de cada peer autenticado.

## Desarrollo y pruebas

Requiere Node.js 22 o posterior.

```sh
npm install
npm run typecheck
npm test
npm run dev
```

Contra un despliegue real se puede validar el recorrido HTTPS/WSS completo con:

```sh
npm run smoke -- https://relay.example
```

Las pruebas usan el runtime Workers local y cubren creación, health, upgrade, autenticación inicial, allowlist, redacción y sobrescritura de `from`, además de helpers de tamaño y rate limit.

## Despliegue

1. Autenticar Wrangler: `npx wrangler login`.
2. Ajustar `name`, `workers_dev` y, si procede, `routes` en `wrangler.jsonc`.
3. Ajustar `ROOM_TTL_SECONDS` en `vars`.
4. Ejecutar `npm run deploy`.
5. Configurar el cliente con el hostname publicado; el endpoint de creación devuelve la URL `wss://` exacta.

`wrangler.jsonc` usa el campo declarativo actual `exports` para crear `Room` como Durable Object SQLite. No se debe añadir a la vez la configuración legacy `migrations`, porque ambos mecanismos son excluyentes.
