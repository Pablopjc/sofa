import { DurableObject } from "cloudflare:workers";
import {
  HELLO_TIMEOUT_MS,
  MAX_PEERS,
  MAX_PENDING_CONNECTIONS,
} from "./config";
import {
  constantTimeEqual,
  consumeRateLimit,
  parseClientFrame,
  sanitizeForRelay,
  type RateState,
} from "./protocol";

export interface Env {
  ROOMS: DurableObjectNamespace<Room>;
  SOCIAL: DurableObjectNamespace<import("./social").SocialHub>;
  ROOM_CREATION_LIMITER: RateLimit;
  ROOM_CONNECT_LIMITER: RateLimit;
  ROOM_TTL_SECONDS?: string;
}

interface RoomMetadata {
  secret: string;
  createdAt: number;
  expiresAt: number;
}

interface SocketAttachment {
  peerID: string;
  authenticated: boolean;
  connectedAt: number;
  helloDeadline: number;
  rate: RateState;
}

interface InitializeRequest {
  secret: string;
  createdAt: number;
  expiresAt: number;
}

const OPEN = 1;

function jsonResponse(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

function randomToken(bytes: number): string {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

export class Room extends DurableObject<Env> {
  private metadataPromise: Promise<RoomMetadata | undefined>;
  private initializing = false;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.metadataPromise = ctx.storage.get<RoomMetadata>("metadata");
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/initialize") {
      return this.initialize(request);
    }
    if (request.method !== "GET" || url.pathname !== "/connect") {
      return jsonResponse({ error: "not_found" }, 404);
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return jsonResponse({ error: "websocket_upgrade_required" }, 426);
    }

    const metadata = await this.metadataPromise;
    if (!metadata) return jsonResponse({ error: "room_not_found" }, 404);
    if (Date.now() >= metadata.expiresAt) {
      await this.expireRoom();
      return jsonResponse({ error: "room_expired" }, 410);
    }

    const liveSockets = this.ctx.getWebSockets().filter((socket) => socket.readyState === OPEN);
    if (liveSockets.length >= MAX_PENDING_CONNECTIONS) {
      return jsonResponse({ error: "too_many_pending_connections" }, 503);
    }

    const [client, server] = Object.values(new WebSocketPair());
    const now = Date.now();
    const attachment: SocketAttachment = {
      peerID: randomToken(12),
      authenticated: false,
      connectedAt: now,
      helloDeadline: now + HELLO_TIMEOUT_MS,
      rate: { windowStartedAt: now, messages: 0 },
    };
    server.serializeAttachment(attachment);
    this.ctx.acceptWebSocket(server);
    await this.scheduleNextAlarm(metadata);

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket: WebSocket, frame: string | ArrayBuffer): Promise<void> {
    const attachment = this.getAttachment(socket);
    if (!attachment) {
      socket.close(1011, "missing socket state");
      return;
    }

    const now = Date.now();
    if (!consumeRateLimit(attachment.rate, now)) {
      socket.serializeAttachment(attachment);
      socket.close(1008, "rate limit exceeded");
      return;
    }
    socket.serializeAttachment(attachment);

    const parsed = parseClientFrame(frame);
    if (!parsed.ok) {
      socket.close(1008, parsed.reason);
      return;
    }

    const metadata = await this.metadataPromise;
    if (!metadata || now >= metadata.expiresAt) {
      socket.close(1008, "room expired");
      if (metadata) await this.expireRoom();
      return;
    }

    if (!attachment.authenticated) {
      if (now >= attachment.helloDeadline) {
        socket.close(1008, "hello timeout");
        return;
      }
      if (parsed.message.type !== "hello" || typeof parsed.message.token !== "string") {
        socket.close(1008, "hello required");
        return;
      }
      if (!constantTimeEqual(parsed.message.token, metadata.secret)) {
        socket.close(1008, "authentication failed");
        return;
      }
      if (this.authenticatedSockets(socket).length >= MAX_PEERS) {
        socket.close(1013, "room full");
        return;
      }

      attachment.authenticated = true;
      socket.serializeAttachment(attachment);
      const peers = this.peerIDs();
      this.safeSend(socket, {
        type: "welcome",
        peerID: attachment.peerID,
        peers,
        expiresAt: metadata.expiresAt,
      });
      const hello = sanitizeForRelay(parsed.message, metadata.secret, attachment.peerID);
      for (const peer of this.authenticatedSockets(socket)) this.safeSend(peer, hello);
      this.broadcastPeerList();
      await this.scheduleNextAlarm(metadata);
      return;
    }

    if (parsed.message.type === "bye") {
      const outgoing = sanitizeForRelay(parsed.message, metadata.secret, attachment.peerID);
      for (const peer of this.authenticatedSockets(socket)) this.safeSend(peer, outgoing);
      attachment.authenticated = false;
      socket.serializeAttachment(attachment);
      socket.close(1000, "bye");
      this.broadcastPeerList();
      return;
    }

    const outgoing = sanitizeForRelay(parsed.message, metadata.secret, attachment.peerID);
    for (const peer of this.authenticatedSockets(socket)) {
      this.safeSend(peer, outgoing);
    }
  }

  async webSocketClose(
    socket: WebSocket,
    code: number,
    reason: string,
    wasClean: boolean,
  ): Promise<void> {
    void code;
    void reason;
    void wasClean;
    const attachment = this.getAttachment(socket);
    if (attachment?.authenticated) this.broadcastPeerList(socket);
    const metadata = await this.metadataPromise;
    if (metadata) await this.scheduleNextAlarm(metadata);
  }

  webSocketError(socket: WebSocket): void {
    const attachment = this.getAttachment(socket);
    if (attachment?.authenticated) this.broadcastPeerList(socket);
  }

  async alarm(): Promise<void> {
    const metadata = await this.metadataPromise;
    if (!metadata) return;
    const now = Date.now();
    if (now >= metadata.expiresAt) {
      await this.expireRoom();
      return;
    }

    for (const socket of this.ctx.getWebSockets()) {
      const attachment = this.getAttachment(socket);
      if (attachment && !attachment.authenticated && now >= attachment.helloDeadline) {
        socket.close(1008, "hello timeout");
      }
    }
    await this.scheduleNextAlarm(metadata);
  }

  private async initialize(request: Request): Promise<Response> {
    if (this.initializing) return jsonResponse({ error: "room_already_exists" }, 409);
    this.initializing = true;
    try {
      if (await this.metadataPromise) return jsonResponse({ error: "room_already_exists" }, 409);

      let body: InitializeRequest;
      try {
        body = (await request.json()) as InitializeRequest;
      } catch {
        return jsonResponse({ error: "invalid_initialization" }, 400);
      }
      if (
        typeof body.secret !== "string" ||
        body.secret.length < 22 ||
        !Number.isSafeInteger(body.createdAt) ||
        !Number.isSafeInteger(body.expiresAt) ||
        body.expiresAt <= body.createdAt
      ) {
        return jsonResponse({ error: "invalid_initialization" }, 400);
      }

      const metadata: RoomMetadata = {
        secret: body.secret,
        createdAt: body.createdAt,
        expiresAt: body.expiresAt,
      };
      await this.ctx.storage.put("metadata", metadata);
      this.metadataPromise = Promise.resolve(metadata);
      await this.ctx.storage.setAlarm(metadata.expiresAt);
      return jsonResponse({ ok: true }, 201);
    } finally {
      this.initializing = false;
    }
  }

  private getAttachment(socket: WebSocket): SocketAttachment | undefined {
    try {
      return socket.deserializeAttachment() as SocketAttachment | undefined;
    } catch {
      return undefined;
    }
  }

  private authenticatedSockets(exclude?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets().filter((socket) => {
      if (socket === exclude || socket.readyState !== OPEN) return false;
      return this.getAttachment(socket)?.authenticated === true;
    });
  }

  private peerIDs(): string[] {
    return this.authenticatedSockets()
      .map((socket) => this.getAttachment(socket)?.peerID)
      .filter((peerID): peerID is string => typeof peerID === "string")
      .sort();
  }

  private broadcastPeerList(exclude?: WebSocket): void {
    const peers = this.peerIDs().filter((peerID) => {
      if (!exclude) return true;
      return peerID !== this.getAttachment(exclude)?.peerID;
    });
    const message = { type: "peers", count: peers.length, peers };
    for (const socket of this.authenticatedSockets(exclude)) this.safeSend(socket, message);
  }

  private safeSend(socket: WebSocket, message: unknown): void {
    try {
      socket.send(JSON.stringify(message));
    } catch {
      // A peer can disconnect between getWebSockets() and send().
    }
  }

  private async scheduleNextAlarm(metadata: RoomMetadata): Promise<void> {
    let nextAlarm = metadata.expiresAt;
    const now = Date.now();
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = this.getAttachment(socket);
      if (
        attachment &&
        !attachment.authenticated &&
        attachment.helloDeadline > now &&
        attachment.helloDeadline < nextAlarm
      ) {
        nextAlarm = attachment.helloDeadline;
      }
    }
    await this.ctx.storage.setAlarm(nextAlarm);
  }

  private async expireRoom(): Promise<void> {
    for (const socket of this.ctx.getWebSockets()) {
      try {
        socket.close(1001, "room expired");
      } catch {
        // The socket may already be closing.
      }
    }
    await this.ctx.storage.deleteAll();
    this.metadataPromise = Promise.resolve(undefined);
  }
}
