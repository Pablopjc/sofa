import { roomTtlMilliseconds } from "./config";
import { Room, type Env } from "./room";
import { SocialHub } from "./social";

export { Room } from "./room";
export { SocialHub } from "./social";

const ROOM_ID_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const ROOM_ID_LENGTH = 6;
const ROOM_ID_PATTERN = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/u;
const MAX_ROOM_ID_ATTEMPTS = 8;
const MAX_CREATE_BODY_BYTES = 256;

function randomToken(bytes: number): string {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function randomRoomID(): string {
  // 32 symbols = exactly 5 random bits per character, so modulo introduces no bias.
  const random = new Uint8Array(ROOM_ID_LENGTH);
  crypto.getRandomValues(random);
  return Array.from(random, (byte) => ROOM_ID_ALPHABET[byte & 31]).join("");
}

function json(body: unknown, status = 200, extraHeaders?: HeadersInit): Response {
  const headers = new Headers(extraHeaders);
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("Cache-Control", "no-store");
  return new Response(JSON.stringify(body), { status, headers });
}

function webSocketURL(requestURL: URL, roomID: string): string {
  const url = new URL(`/v1/rooms/${roomID}`, requestURL.origin);
  url.protocol = requestURL.protocol === "https:" ? "wss:" : "ws:";
  return url.toString();
}

async function createRoom(request: Request, env: Env): Promise<Response> {
  const secret = randomToken(32);
  const createdAt = Date.now();
  const expiresAt = createdAt + roomTtlMilliseconds(env.ROOM_TTL_SECONDS);
  for (let attempt = 0; attempt < MAX_ROOM_ID_ATTEMPTS; attempt += 1) {
    const roomID = randomRoomID();
    const stub = env.ROOMS.get(env.ROOMS.idFromName(roomID));
    const response = await stub.fetch("https://room.internal/initialize", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ secret, createdAt, expiresAt }),
    });
    if (response.status === 409) continue;
    if (!response.ok) return json({ error: "room_creation_failed" }, 503);

    return json(
      {
        roomID,
        secret,
        webSocketURL: webSocketURL(new URL(request.url), roomID),
        inviteURL: `sofa://join/v1/${roomID}/${secret}`,
        expiresAt,
      },
      201,
    );
  }
  return json({ error: "room_id_space_busy" }, 503);
}

async function connectToRoom(request: Request, env: Env, roomID: string): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return json({ error: "websocket_upgrade_required" }, 426, { Upgrade: "websocket" });
  }
  const networkActor = request.headers.get("CF-Connecting-IP") ?? "local-development";
  const admission = await env.ROOM_CONNECT_LIMITER.limit({ key: `${roomID}:${networkActor}` });
  if (!admission.success) {
    return json({ error: "room_connection_rate_limited" }, 429, { "Retry-After": "60" });
  }
  const stub = env.ROOMS.get(env.ROOMS.idFromName(roomID));
  return stub.fetch(new Request("https://room.internal/connect", request));
}

// Human-friendly invite page. The room secret travels only in the URL
// fragment (#…), which browsers never send to the server, so this page can be
// served (and cached) without ever seeing the capability secret.
function invitePage(roomID: string): Response {
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Join the Sofa party ${roomID}</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    background: #101114; color: #f2f3f5; text-align: center;
  }
  @media (prefers-color-scheme: light) { body { background: #f3f4f6; color: #1c1c1e; } }
  .card { max-width: 340px; padding: 40px 28px; }
  .glyph { font-size: 56px; }
  h1 { font-size: 22px; margin: 14px 0 6px; }
  p { font-size: 14px; line-height: 1.45; opacity: 0.75; margin: 8px 0; }
  .code { font-family: ui-monospace, monospace; font-weight: 700; letter-spacing: 3px; }
  a.button {
    display: block; margin: 22px 0 10px; padding: 13px 22px; border-radius: 999px;
    background: #0A84FF; color: #fff; font-size: 16px; font-weight: 600; text-decoration: none;
  }
  a.plain { color: #0A84FF; font-size: 13px; text-decoration: none; }
  .hidden { display: none; }
</style>
</head>
<body>
<div class="card">
  <div class="glyph">🛋️</div>
  <h1>Movie night awaits</h1>
  <p>You’re invited to Sofa party <span class="code">${roomID}</span> — synchronized play, pause and skips with your friend.</p>
  <a id="open" class="button" href="#">Open in Sofa</a>
  <p id="broken" class="hidden">This invite link is incomplete — ask your friend to copy it again from Sofa.</p>
  <p>Don’t have Sofa yet? <a class="plain" href="https://github.com/Pablopjc/sofa/releases/latest">Download it free for Mac</a>, then come back and tap the button.</p>
</div>
<script>
  var secret = location.hash.replace(/^#/, "");
  var open = document.getElementById("open");
  if (/^[A-Za-z0-9_-]{43}$/.test(secret)) {
    var deepLink = "sofa://join/v1/${roomID}/" + secret;
    open.setAttribute("href", deepLink);
    location.href = deepLink; // auto-open when Sofa is installed
  } else {
    open.classList.add("hidden");
    document.getElementById("broken").classList.remove("hidden");
  }
</script>
</body>
</html>`;
  return new Response(html, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
      "Content-Security-Policy":
        "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'",
    },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && (url.pathname === "/health" || url.pathname === "/healthz")) {
      return json({ ok: true, service: "sofa-sync-relay" });
    }
    if (request.method === "GET") {
      const inviteMatch = /^\/j\/([^/]+)$/u.exec(url.pathname);
      if (inviteMatch) {
        const roomID = inviteMatch[1].toUpperCase();
        if (!ROOM_ID_PATTERN.test(roomID)) return json({ error: "invalid_room_id" }, 404);
        return invitePage(roomID);
      }
    }
    if (url.pathname.startsWith("/v1/social/")) {
      const actor = request.headers.get("CF-Connecting-IP") ?? "social";
      const admission = await env.ROOM_CONNECT_LIMITER.limit({ key: `social:${actor}` });
      if (!admission.success) return json({ error: "social_rate_limited" }, 429, { "Retry-After": "60" });
      const stub = env.SOCIAL.get(env.SOCIAL.idFromName("global"));
      const internalURL = new URL(request.url);
      internalURL.pathname = url.pathname.slice("/v1/social".length) || "/";
      return stub.fetch(new Request(internalURL, request));
    }
    if (request.method === "POST" && url.pathname === "/v1/rooms") {
      const contentType = request.headers.get("Content-Type")?.split(";", 1)[0].trim();
      const clientID = request.headers.get("X-Sofa-Client-ID") ?? "";
      const protocol = request.headers.get("X-Sofa-Protocol");
      if (
        contentType !== "application/json" ||
        protocol !== "1" ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(
          clientID,
        )
      ) {
        return json({ error: "invalid_client" }, 400);
      }

      const networkActor = request.headers.get("CF-Connecting-IP") ?? clientID.toLowerCase();
      const creation = await env.ROOM_CREATION_LIMITER.limit({ key: networkActor });
      if (!creation.success) {
        return json({ error: "room_creation_rate_limited" }, 429, { "Retry-After": "60" });
      }

      const advertisedLength = Number(request.headers.get("Content-Length") ?? 0);
      if (Number.isFinite(advertisedLength) && advertisedLength > MAX_CREATE_BODY_BYTES) {
        return json({ error: "invalid_body" }, 400);
      }

      let rawBody: string;
      try {
        rawBody = await request.text();
      } catch {
        return json({ error: "invalid_json" }, 400);
      }
      if (new TextEncoder().encode(rawBody).byteLength > MAX_CREATE_BODY_BYTES) {
        return json({ error: "invalid_body" }, 400);
      }

      let body: unknown;
      try {
        body = JSON.parse(rawBody);
      } catch {
        return json({ error: "invalid_json" }, 400);
      }
      if (body === null || typeof body !== "object" || Array.isArray(body)) {
        return json({ error: "invalid_json" }, 400);
      }
      if (Object.keys(body).length !== 0) {
        return json({ error: "invalid_body" }, 400);
      }
      return createRoom(request, env);
    }
    if (request.method === "GET") {
      const match = /^\/v1\/rooms\/([^/]+)$/u.exec(url.pathname);
      if (match) {
        const roomID = match[1];
        if (!ROOM_ID_PATTERN.test(roomID)) return json({ error: "invalid_room_id" }, 400);
        return connectToRoom(request, env, roomID);
      }
    }

    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
