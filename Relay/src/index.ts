import { roomTtlMilliseconds } from "./config";
import { Room, type Env } from "./room";

export { Room } from "./room";

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

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && (url.pathname === "/health" || url.pathname === "/healthz")) {
      return json({ ok: true, service: "sofa-sync-relay" });
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
