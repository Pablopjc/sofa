import assert from "node:assert/strict";

const baseURL = process.argv[2]?.replace(/\/$/u, "");
if (!baseURL) {
  throw new Error("usage: npm run smoke -- https://relay.example");
}

class Inbox {
  constructor(socket) {
    this.messages = [];
    this.waiters = [];
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data));
      const index = this.waiters.findIndex(({ predicate }) => predicate(message));
      if (index >= 0) {
        const [{ resolve, timer }] = this.waiters.splice(index, 1);
        clearTimeout(timer);
        resolve(message);
      } else {
        this.messages.push(message);
      }
    });
  }

  next(predicate, timeout = 8_000) {
    const existing = this.messages.findIndex(predicate);
    if (existing >= 0) return Promise.resolve(this.messages.splice(existing, 1)[0]);
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve, timer: undefined };
      waiter.timer = setTimeout(() => {
        this.waiters = this.waiters.filter((entry) => entry !== waiter);
        reject(new Error("timed out waiting for relay frame"));
      }, timeout);
      this.waiters.push(waiter);
    });
  }
}

function openSocket(url) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    const inbox = new Inbox(socket);
    socket.addEventListener("open", () => resolve({ socket, inbox }), { once: true });
    socket.addEventListener("error", () => reject(new Error("WebSocket failed to open")), {
      once: true,
    });
  });
}

const health = await fetch(`${baseURL}/health`);
assert.equal(health.status, 200);
assert.equal((await health.json()).ok, true);

const created = await fetch(`${baseURL}/v1/rooms`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-Sofa-Client-ID": crypto.randomUUID(),
    "X-Sofa-Protocol": "1",
  },
  body: "{}",
});
assert.equal(created.status, 201);
const room = await created.json();
assert.match(room.roomID, /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/u);
assert.match(room.secret, /^[A-Za-z0-9_-]{43}$/u);

async function registerSocial(name, clientID) {
  const response = await fetch(`${baseURL}/v1/social/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Sofa-Client-ID": clientID },
    body: JSON.stringify({ name }),
  });
  assert.equal(response.status, 201);
  return response.json();
}

const socialA = await registerSocial(`Smoke A ${crypto.randomUUID().slice(0, 6)}`, crypto.randomUUID());
const socialB = await registerSocial(`Smoke B ${crypto.randomUUID().slice(0, 6)}`, crypto.randomUUID());
const authA = `Bearer ${socialA.id}.${socialA.authToken}`;
const authB = `Bearer ${socialB.id}.${socialB.authToken}`;
const friendCode = socialA.friendLink.split("/").at(-1);
const pairing = await fetch(`${baseURL}/v1/social/friends/accept`, {
  method: "POST",
  headers: { Authorization: authB, "Content-Type": "application/json" },
  body: JSON.stringify({ friendID: socialA.id, code: friendCode }),
});
assert.equal(pairing.status, 200);
const saved = await fetch(`${baseURL}/v1/social/friends`, { headers: { Authorization: authA } });
assert.equal(saved.status, 200);
assert.equal((await saved.json()).friends.some((friend) => friend.id === socialB.id), true);
const socialInvite = await fetch(`${baseURL}/v1/social/invites`, {
  method: "POST",
  headers: { Authorization: authA, "Content-Type": "application/json" },
  body: JSON.stringify({
    friendID: socialB.id, roomID: room.roomID, secret: room.secret, title: "Smoke movie",
  }),
});
assert.equal(socialInvite.status, 201);

const first = await openSocket(room.webSocketURL);
first.socket.send(JSON.stringify({ type: "hello", token: room.secret, name: "Spain" }));
const firstWelcome = await first.inbox.next((message) => message.type === "welcome");
await first.inbox.next((message) => message.type === "peers" && message.count === 1);

const second = await openSocket(room.webSocketURL);
second.socket.send(
  JSON.stringify({ type: "hello", token: room.secret, name: "Germany", from: "spoofed" }),
);
const secondWelcome = await second.inbox.next((message) => message.type === "welcome");
const joined = await first.inbox.next((message) => message.type === "hello");
assert.equal(joined.name, "Germany");
assert.equal(joined.from, secondWelcome.peerID);
assert.equal("token" in joined, false);
await first.inbox.next((message) => message.type === "peers" && message.count === 2);
await second.inbox.next((message) => message.type === "peers" && message.count === 2);

second.socket.send(JSON.stringify({
  type: "loaded",
  name: "Shared episode",
  art: "https://images.example/poster.jpg",
  url: "https://www.netflix.com/watch/1234",
  time: 19,
  playing: false,
}));
const loaded = await first.inbox.next((message) => message.type === "loaded");
assert.equal(loaded.name, "Shared episode");
assert.equal(loaded.url, "https://www.netflix.com/watch/1234");
assert.equal(loaded.time, 19);

second.socket.send(
  JSON.stringify({ type: "play", time: 42, sentAt: Date.now(), from: "spoofed" }),
);
const play = await first.inbox.next((message) => message.type === "play");
assert.equal(play.time, 42);
assert.equal(play.from, secondWelcome.peerID);
assert.notEqual(play.from, "spoofed");
assert.notEqual(firstWelcome.peerID, secondWelcome.peerID);

second.socket.send(JSON.stringify({ type: "bye" }));
const bye = await first.inbox.next((message) => message.type === "bye");
assert.equal(bye.from, secondWelcome.peerID);
await first.inbox.next((message) => message.type === "peers" && message.count === 1);

first.socket.close(1000, "smoke complete");
console.log("Remote relay smoke test passed: rooms, saved friends, invitation, WSS sync");
