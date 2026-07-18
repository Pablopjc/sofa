import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

interface CreatedRoom {
  roomID: string;
  secret: string;
  webSocketURL: string;
  inviteURL: string;
  expiresAt: number;
}

let nextTestAddress = 1;

interface CreateRequestOptions {
  body?: string;
  clientID?: string | null;
  contentType?: string | null;
  ip?: string;
  protocol?: string | null;
}

class MessageQueue {
  private readonly pending: Array<(value: Record<string, unknown>) => void> = [];
  private readonly messages: Array<Record<string, unknown>> = [];

  constructor(socket: WebSocket) {
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data as string) as Record<string, unknown>;
      const resolve = this.pending.shift();
      if (resolve) resolve(message);
      else this.messages.push(message);
    });
  }

  next(): Promise<Record<string, unknown>> {
    const message = this.messages.shift();
    if (message) return Promise.resolve(message);
    return new Promise((resolve) => this.pending.push(resolve));
  }
}

async function requestRoom(options: CreateRequestOptions = {}): Promise<Response> {
  const headers = new Headers();
  const contentType = options.contentType === undefined ? "application/json" : options.contentType;
  const clientID = options.clientID === undefined ? crypto.randomUUID() : options.clientID;
  const protocol = options.protocol === undefined ? "1" : options.protocol;
  if (contentType !== null) headers.set("Content-Type", contentType);
  if (clientID !== null) headers.set("X-Sofa-Client-ID", clientID);
  if (protocol !== null) headers.set("X-Sofa-Protocol", protocol);
  headers.set(
    "CF-Connecting-IP",
    options.ip ?? `203.0.113.${nextTestAddress++}`,
  );
  return SELF.fetch("https://relay.test/v1/rooms", {
    method: "POST",
    headers,
    body: options.body ?? "{}",
  });
}

async function createRoom(options: CreateRequestOptions = {}): Promise<CreatedRoom> {
  const response = await requestRoom(options);
  expect(response.status).toBe(201);
  return response.json<CreatedRoom>();
}

async function connect(
  roomID: string,
  ip = `198.51.100.${nextTestAddress++}`,
): Promise<{ socket: WebSocket; messages: MessageQueue }> {
  const response = await SELF.fetch(`https://relay.test/v1/rooms/${roomID}`, {
    headers: { Upgrade: "websocket", "CF-Connecting-IP": ip },
  });
  expect(response.status).toBe(101);
  const socket = response.webSocket;
  if (!socket) throw new Error("Expected a WebSocket response");
  socket.accept();
  return { socket, messages: new MessageQueue(socket) };
}

describe("relay worker", () => {
  it("reports health and creates visible room codes with strong secrets", async () => {
    const health = await SELF.fetch("https://relay.test/health");
    expect(await health.json()).toEqual({ ok: true, service: "sofa-sync-relay" });

    const first = await createRoom();
    const second = await createRoom();
    expect(first.roomID).toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/u);
    expect(first.secret).toMatch(/^[A-Za-z0-9_-]{43}$/u);
    expect(first.roomID).not.toBe(second.roomID);
    expect(first.secret).not.toBe(second.secret);
    expect(first.webSocketURL).toBe(`wss://relay.test/v1/rooms/${first.roomID}`);
    expect(first.inviteURL).toBe(`sofa://join/v1/${first.roomID}/${first.secret}`);
    expect(first.expiresAt).toBeGreaterThan(Date.now());
  });

  it("requires the native-client headers and an empty bounded JSON body", async () => {
    const missingClient = await requestRoom({ clientID: null });
    expect(missingClient.status).toBe(400);
    expect(await missingClient.json()).toEqual({ error: "invalid_client" });

    expect((await requestRoom({ contentType: "text/plain" })).status).toBe(400);
    expect((await requestRoom({ protocol: "2" })).status).toBe(400);
    expect((await requestRoom({ clientID: "rotatable-but-not-a-uuid" })).status).toBe(400);
    expect((await requestRoom({ body: "not-json" })).status).toBe(400);
    expect((await requestRoom({ body: "[]" })).status).toBe(400);
    expect((await requestRoom({ body: '{"unexpected":true}' })).status).toBe(400);
    const oversized = await requestRoom({ body: "x".repeat(257) });
    expect(oversized.status).toBe(400);
    expect(await oversized.json()).toEqual({ error: "invalid_body" });
  });

  it("limits room creation by source IP even when client IDs rotate", async () => {
    const ip = "203.0.113.250";
    for (let index = 0; index < 12; index += 1) {
      expect((await requestRoom({ ip, clientID: crypto.randomUUID() })).status).toBe(201);
    }
    const limited = await requestRoom({ ip, clientID: crypto.randomUUID() });
    expect(limited.status).toBe(429);
    expect(limited.headers.get("Retry-After")).toBe("60");
    expect(await limited.json()).toEqual({ error: "room_creation_rate_limited" });
  });

  it("requires hello first and relays only sanitized allowlisted messages", async () => {
    const room = await createRoom();
    const first = await connect(room.roomID);
    const second = await connect(room.roomID);

    first.socket.send(JSON.stringify({ type: "hello", token: room.secret, name: "first" }));
    const firstWelcome = await first.messages.next();
    expect(firstWelcome.type).toBe("welcome");
    const firstPeerID = firstWelcome.peerID;
    expect(typeof firstPeerID).toBe("string");
    expect(await first.messages.next()).toMatchObject({ type: "peers", count: 1 });

    second.socket.send(JSON.stringify({ type: "hello", token: room.secret, name: "second" }));
    const secondWelcome = await second.messages.next();
    expect(secondWelcome.type).toBe("welcome");
    expect(await second.messages.next()).toMatchObject({ type: "peers", count: 2 });
    const initialHello = await first.messages.next();
    expect(initialHello).toEqual({ type: "hello", name: "second", from: secondWelcome.peerID });
    expect(JSON.stringify(initialHello)).not.toContain(room.secret);
    expect(await first.messages.next()).toMatchObject({ type: "peers", count: 2 });

    second.socket.send(
      JSON.stringify({ type: "hello", token: room.secret, name: "second-updated", from: "spoofed" }),
    );
    const periodicHello = await first.messages.next();
    expect(periodicHello).toEqual({
      type: "hello",
      name: "second-updated",
      from: secondWelcome.peerID,
    });
    expect(JSON.stringify(periodicHello)).not.toContain(room.secret);

    second.socket.send(
      JSON.stringify({
        type: "seek",
        time: 42,
        playing: true,
        from: "spoofed",
      }),
    );
    const relayed = await first.messages.next();
    expect(relayed).toEqual({
      type: "seek",
      time: 42,
      playing: true,
      from: secondWelcome.peerID,
    });
    expect(JSON.stringify(relayed)).not.toContain(room.secret);

    first.socket.close(1000, "done");
    second.socket.close(1000, "done");
  });

  it("closes a connection whose first frame is not hello", async () => {
    const room = await createRoom();
    const peer = await connect(room.roomID);
    const closed = new Promise<CloseEvent>((resolve) => {
      peer.socket.addEventListener("close", (event) => resolve(event));
    });
    peer.socket.send(JSON.stringify({ type: "play", time: 0 }));
    const event = await closed;
    expect(event.code).toBe(1008);
    expect(event.reason).toBe("hello required");
  });

  it("rejects an incorrect room secret", async () => {
    const room = await createRoom();
    const peer = await connect(room.roomID);
    const closed = new Promise<CloseEvent>((resolve) => {
      peer.socket.addEventListener("close", (event) => resolve(event), { once: true });
    });
    peer.socket.send(JSON.stringify({ type: "hello", token: "wrong-secret" }));
    const event = await closed;
    expect(event.code).toBe(1008);
    expect(event.reason).toBe("authentication failed");
  });

  it("enforces the per-socket frame rate after authentication", async () => {
    const room = await createRoom();
    const peer = await connect(room.roomID);
    peer.socket.send(JSON.stringify({ type: "hello", token: room.secret }));
    expect((await peer.messages.next()).type).toBe("welcome");
    await peer.messages.next();

    const closed = new Promise<CloseEvent>((resolve) => {
      peer.socket.addEventListener("close", (event) => resolve(event), { once: true });
    });
    for (let index = 0; index < 60; index += 1) {
      peer.socket.send(JSON.stringify({ type: "tick", time: index }));
    }
    const event = await closed;
    expect(event.code).toBe(1008);
    expect(event.reason).toBe("rate limit exceeded");
  });

  it("relays bye once and publishes the reduced peer count", async () => {
    const room = await createRoom();
    const first = await connect(room.roomID);
    const second = await connect(room.roomID);
    first.socket.send(JSON.stringify({ type: "hello", token: room.secret, name: "first" }));
    await first.messages.next();
    await first.messages.next();
    second.socket.send(JSON.stringify({ type: "hello", token: room.secret, name: "second" }));
    await second.messages.next();
    await second.messages.next();
    await first.messages.next();
    await first.messages.next();

    second.socket.send(JSON.stringify({ type: "bye" }));
    expect(await first.messages.next()).toMatchObject({ type: "bye" });
    expect(await first.messages.next()).toMatchObject({ type: "peers", count: 1 });
    first.socket.close(1000, "done");
  });

  it("admits at most eight authenticated peers", async () => {
    const room = await createRoom();
    const admitted: WebSocket[] = [];
    for (let index = 0; index < 8; index += 1) {
      const peer = await connect(room.roomID);
      peer.socket.send(JSON.stringify({ type: "hello", token: room.secret }));
      expect((await peer.messages.next()).type).toBe("welcome");
      admitted.push(peer.socket);
    }

    const ninth = await connect(room.roomID);
    const closed = new Promise<CloseEvent>((resolve) => {
      ninth.socket.addEventListener("close", (event) => resolve(event));
    });
    ninth.socket.send(JSON.stringify({ type: "hello", token: room.secret }));
    const event = await closed;
    expect(event.code).toBe(1013);
    expect(event.reason).toBe("room full");

    for (const socket of admitted) socket.close(1000, "done");
  });

  it("rejects malformed room ids and non-WebSocket room requests", async () => {
    expect((await SELF.fetch("https://relay.test/v1/rooms/not-valid")).status).toBe(400);
    const room = await createRoom();
    const response = await SELF.fetch(`https://relay.test/v1/rooms/${room.roomID}`);
    expect(response.status).toBe(426);
  });

  it("limits WebSocket admission per room and source IP", async () => {
    const roomID = "AAAAAA";
    const ip = "198.51.100.250";
    for (let index = 0; index < 60; index += 1) {
      const response = await SELF.fetch(`https://relay.test/v1/rooms/${roomID}`, {
        headers: { Upgrade: "websocket", "CF-Connecting-IP": ip },
      });
      expect(response.status).toBe(404);
    }
    const limited = await SELF.fetch(`https://relay.test/v1/rooms/${roomID}`, {
      headers: { Upgrade: "websocket", "CF-Connecting-IP": ip },
    });
    expect(limited.status).toBe(429);
    expect(limited.headers.get("Retry-After")).toBe("60");
    expect(await limited.json()).toEqual({ error: "room_connection_rate_limited" });
  });
});
