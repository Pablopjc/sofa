import { DurableObject } from "cloudflare:workers";
import { constantTimeEqual } from "./protocol";

export interface SocialEnv {}

interface StoredFriend { name: string }
interface StoredUser {
  id: string;
  name: string;
  authHash: string;
  friendCode: string;
  friends: Record<string, StoredFriend>;
  createdAt: number;
}
interface StoredInvite {
  id: string;
  fromID: string;
  fromName: string;
  roomID: string;
  secret: string;
  title?: string;
  createdAt: number;
  expiresAt: number;
}
interface SocialSocketAttachment { userID: string }

const USER_ID = /^[A-Za-z0-9_-]{22}$/u;
const FRIEND_CODE = /^[A-Za-z0-9_-]{24}$/u;
const ROOM_ID = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/u;
const ROOM_SECRET = /^[A-Za-z0-9_-]{43}$/u;
const MAX_FRIENDS = 50;
const INVITE_LIFETIME_MS = 15 * 60 * 1_000;
const OPEN = 1;

function randomToken(bytes: number): string {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

async function tokenHash(token: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function cleanName(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const name = value.replace(/[\u0000-\u001f\u007f]/gu, " ").trim().slice(0, 40);
  return name || undefined;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

export class SocialHub extends DurableObject<SocialEnv> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/register") return this.register(request);

    const user = await this.authenticate(request);
    if (!user) return json({ error: "unauthorized" }, 401);

    if (request.method === "GET" && url.pathname === "/events") {
      return this.connectEvents(request, user);
    }
    if (request.method === "GET" && url.pathname === "/me") return json(this.publicProfile(user));
    if (request.method === "PATCH" && url.pathname === "/me") return this.updateProfile(request, user);
    if (request.method === "GET" && url.pathname === "/friends") return this.listFriends(user);
    if (request.method === "POST" && url.pathname === "/friends/accept") {
      return this.acceptFriend(request, user);
    }
    if (request.method === "POST" && url.pathname === "/invites") {
      return this.createInvite(request, user);
    }
    const inviteMatch = /^\/invites\/([A-Za-z0-9_-]{16})$/u.exec(url.pathname);
    if (request.method === "DELETE" && inviteMatch) {
      await this.ctx.storage.delete(`invite:${user.id}:${inviteMatch[1]}`);
      return json({ ok: true });
    }
    return json({ error: "not_found" }, 404);
  }

  async webSocketClose(): Promise<void> {}
  async webSocketError(): Promise<void> {}

  private async register(request: Request): Promise<Response> {
    const body = await this.body(request);
    const name = cleanName(body?.name);
    if (!name) return json({ error: "invalid_name" }, 400);
    let id = randomToken(16);
    while (await this.ctx.storage.get(`user:${id}`)) id = randomToken(16);
    const authToken = randomToken(32);
    const user: StoredUser = {
      id,
      name,
      authHash: await tokenHash(authToken),
      friendCode: randomToken(18),
      friends: {},
      createdAt: Date.now(),
    };
    await this.ctx.storage.put(`user:${id}`, user);
    return json({ ...this.publicProfile(user), authToken }, 201);
  }

  private async authenticate(request: Request): Promise<StoredUser | undefined> {
    const match = /^Bearer ([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{43})$/u.exec(
      request.headers.get("Authorization") ?? "",
    );
    if (!match) return undefined;
    const user = await this.ctx.storage.get<StoredUser>(`user:${match[1]}`);
    if (!user || !constantTimeEqual(user.authHash, await tokenHash(match[2]))) return undefined;
    return user;
  }

  private publicProfile(user: StoredUser): Record<string, unknown> {
    return {
      id: user.id,
      name: user.name,
      friendLink: `sofa://friend/v1/${user.id}/${user.friendCode}`,
    };
  }

  private async updateProfile(request: Request, user: StoredUser): Promise<Response> {
    const body = await this.body(request);
    const name = cleanName(body?.name);
    if (!name) return json({ error: "invalid_name" }, 400);
    user.name = name;
    await this.ctx.storage.put(`user:${user.id}`, user);
    for (const friendID of Object.keys(user.friends)) {
      const friend = await this.ctx.storage.get<StoredUser>(`user:${friendID}`);
      if (!friend?.friends[user.id]) continue;
      friend.friends[user.id] = { name };
      await this.ctx.storage.put(`user:${friend.id}`, friend);
    }
    return json(this.publicProfile(user));
  }

  private listFriends(user: StoredUser): Response {
    return json({
      friends: Object.entries(user.friends)
        .map(([id, friend]) => ({ id, name: friend.name, online: this.isOnline(id) }))
        .sort((a, b) => a.name.localeCompare(b.name)),
    });
  }

  private async acceptFriend(request: Request, user: StoredUser): Promise<Response> {
    const body = await this.body(request);
    const friendID = typeof body?.friendID === "string" ? body.friendID : "";
    const code = typeof body?.code === "string" ? body.code : "";
    if (!USER_ID.test(friendID) || !FRIEND_CODE.test(code) || friendID === user.id) {
      return json({ error: "invalid_friend_link" }, 400);
    }
    const friend = await this.ctx.storage.get<StoredUser>(`user:${friendID}`);
    if (!friend || friend.friendCode !== code) return json({ error: "invalid_friend_link" }, 404);
    if (!user.friends[friendID] && Object.keys(user.friends).length >= MAX_FRIENDS) {
      return json({ error: "friend_limit" }, 409);
    }
    if (!friend.friends[user.id] && Object.keys(friend.friends).length >= MAX_FRIENDS) {
      return json({ error: "friend_limit" }, 409);
    }
    user.friends[friend.id] = { name: friend.name };
    friend.friends[user.id] = { name: user.name };
    await this.ctx.storage.put({ [`user:${user.id}`]: user, [`user:${friend.id}`]: friend });
    this.sendTo(user.id, { type: "friends_changed" });
    this.sendTo(friend.id, { type: "friend_added", friend: { id: user.id, name: user.name } });
    return json({ friend: { id: friend.id, name: friend.name } });
  }

  private async createInvite(request: Request, user: StoredUser): Promise<Response> {
    const body = await this.body(request);
    const friendID = typeof body?.friendID === "string" ? body.friendID : "";
    const roomID = typeof body?.roomID === "string" ? body.roomID : "";
    const secret = typeof body?.secret === "string" ? body.secret : "";
    const title = typeof body?.title === "string" ? body.title.trim().slice(0, 256) : undefined;
    if (!user.friends[friendID]) return json({ error: "not_friends" }, 403);
    if (!ROOM_ID.test(roomID) || !ROOM_SECRET.test(secret)) return json({ error: "invalid_room" }, 400);
    const invite: StoredInvite = {
      id: randomToken(12), fromID: user.id, fromName: user.name,
      roomID, secret, title: title || undefined,
      createdAt: Date.now(), expiresAt: Date.now() + INVITE_LIFETIME_MS,
    };
    await this.ctx.storage.put(`invite:${friendID}:${invite.id}`, invite);
    this.sendTo(friendID, { type: "party_invite", invite });
    return json({ ok: true, delivered: this.isOnline(friendID) }, 201);
  }

  private async connectEvents(request: Request, user: StoredUser): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "websocket_upgrade_required" }, 426);
    }
    const [client, server] = Object.values(new WebSocketPair());
    server.serializeAttachment({ userID: user.id } satisfies SocialSocketAttachment);
    this.ctx.acceptWebSocket(server);
    const pending = await this.ctx.storage.list<StoredInvite>({ prefix: `invite:${user.id}:` });
    for (const [key, invite] of pending.entries()) {
      if (invite.expiresAt > Date.now()) this.safeSend(server, { type: "party_invite", invite });
      else await this.ctx.storage.delete(key);
    }
    this.safeSend(server, { type: "social_ready" });
    return new Response(null, { status: 101, webSocket: client });
  }

  private isOnline(userID: string): boolean {
    return this.ctx.getWebSockets().some((socket) =>
      socket.readyState === OPEN &&
      (socket.deserializeAttachment() as SocialSocketAttachment | undefined)?.userID === userID
    );
  }

  private sendTo(userID: string, message: unknown): void {
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socket.deserializeAttachment() as SocialSocketAttachment | undefined;
      if (socket.readyState === OPEN && attachment?.userID === userID) this.safeSend(socket, message);
    }
  }

  private safeSend(socket: WebSocket, message: unknown): void {
    try { socket.send(JSON.stringify(message)); } catch { /* reconnect will fetch pending state */ }
  }

  private async body(request: Request): Promise<Record<string, unknown> | undefined> {
    const length = Number(request.headers.get("Content-Length") ?? 0);
    if (Number.isFinite(length) && length > 4_096) return undefined;
    try {
      const text = await request.text();
      if (new TextEncoder().encode(text).byteLength > 4_096) return undefined;
      const value = JSON.parse(text) as unknown;
      return value !== null && typeof value === "object" && !Array.isArray(value)
        ? value as Record<string, unknown> : undefined;
    } catch { return undefined; }
  }
}
