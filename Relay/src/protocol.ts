import {
  MAX_FRAME_BYTES,
  RATE_LIMIT_MESSAGES,
  RATE_LIMIT_WINDOW_MS,
} from "./config";

export const CLIENT_MESSAGE_TYPES = [
  "hello",
  "loaded",
  "play",
  "pause",
  "seek",
  "tick",
  "bye",
] as const;

export type ClientMessageType = (typeof CLIENT_MESSAGE_TYPES)[number];
export type JsonObject = Record<string, unknown>;

const allowedTypes = new Set<string>(CLIENT_MESSAGE_TYPES);
const encoder = new TextEncoder();
const commonFields = new Set(["type", "from", "sentAt"]);
const fieldsByType: Record<ClientMessageType, ReadonlySet<string>> = {
  hello: new Set(["token", "name"]),
  loaded: new Set(["name", "art", "url", "time", "playing"]),
  play: new Set(["time", "playing", "name", "art", "url"]),
  pause: new Set(["time", "playing", "name", "art", "url"]),
  seek: new Set(["time", "playing", "name", "art", "url"]),
  tick: new Set(["time", "playing", "name", "art", "url"]),
  bye: new Set(),
};
const requiredFieldsByType: Record<ClientMessageType, readonly string[]> = {
  hello: [],
  loaded: ["name"],
  play: ["time"],
  pause: ["time"],
  seek: ["time", "playing"],
  tick: ["time"],
  bye: [],
};

export interface RateState {
  windowStartedAt: number;
  messages: number;
}

export type ParseResult =
  | { ok: true; message: JsonObject & { type: ClientMessageType } }
  | { ok: false; reason: string };

export function frameByteLength(frame: string | ArrayBuffer): number {
  return typeof frame === "string" ? encoder.encode(frame).byteLength : frame.byteLength;
}

export function parseClientFrame(frame: string | ArrayBuffer): ParseResult {
  if (frameByteLength(frame) > MAX_FRAME_BYTES) {
    return { ok: false, reason: "frame_too_large" };
  }
  if (typeof frame !== "string") {
    return { ok: false, reason: "binary_not_supported" };
  }

  let value: unknown;
  try {
    value = JSON.parse(frame);
  } catch {
    return { ok: false, reason: "invalid_json" };
  }

  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, reason: "message_must_be_object" };
  }
  const message = value as JsonObject;
  if (typeof message.type !== "string" || !allowedTypes.has(message.type)) {
    return { ok: false, reason: "message_type_not_allowed" };
  }
  if (Object.keys(message).length > 32) {
    return { ok: false, reason: "too_many_fields" };
  }

  const type = message.type as ClientMessageType;
  const typeFields = fieldsByType[type];
  for (const key of Object.keys(message)) {
    if (!commonFields.has(key) && !typeFields.has(key)) {
      return { ok: false, reason: "field_not_allowed" };
    }
  }
  for (const key of requiredFieldsByType[type]) {
    if (message[key] === undefined) {
      return { ok: false, reason: "missing_required_field" };
    }
  }
  if (message.from !== undefined && (typeof message.from !== "string" || message.from.length > 128)) {
    return { ok: false, reason: "invalid_from" };
  }
  if (
    message.sentAt !== undefined &&
    (typeof message.sentAt !== "number" || !Number.isFinite(message.sentAt) || message.sentAt < 0)
  ) {
    return { ok: false, reason: "invalid_sent_at" };
  }
  if (
    message.token !== undefined &&
    (typeof message.token !== "string" ||
      message.token.length < 1 ||
      message.token.length > 128 ||
      !/^[A-Za-z0-9_-]+$/u.test(message.token))
  ) {
    return { ok: false, reason: "invalid_token" };
  }
  if (
    message.name !== undefined &&
    (typeof message.name !== "string" || message.name.length > 256)
  ) {
    return { ok: false, reason: "invalid_name" };
  }
  if (
    message.art !== undefined &&
    (typeof message.art !== "string" || message.art.length > 4_096 || !isSafeWebURL(message.art))
  ) {
    return { ok: false, reason: "invalid_art" };
  }
  if (
    message.url !== undefined &&
    (typeof message.url !== "string" || message.url.length > 4_096 || !isSafeWebURL(message.url))
  ) {
    return { ok: false, reason: "invalid_url" };
  }
  if (
    message.time !== undefined &&
    (typeof message.time !== "number" ||
      !Number.isFinite(message.time) ||
      message.time < 0 ||
      message.time > 1_000_000_000)
  ) {
    return { ok: false, reason: "invalid_time" };
  }
  if (message.playing !== undefined && typeof message.playing !== "boolean") {
    return { ok: false, reason: "invalid_playing" };
  }

  return {
    ok: true,
    message: message as JsonObject & { type: ClientMessageType },
  };
}

function isSafeWebURL(value: string): boolean {
  try {
    const url = new URL(value);
    return (url.protocol === "https:" || url.protocol === "http:") &&
      url.username === "" && url.password === "";
  } catch {
    return false;
  }
}

export function consumeRateLimit(state: RateState, now: number): boolean {
  if (now - state.windowStartedAt >= RATE_LIMIT_WINDOW_MS) {
    state.windowStartedAt = now;
    state.messages = 1;
    return true;
  }
  state.messages += 1;
  return state.messages <= RATE_LIMIT_MESSAGES;
}

export function constantTimeEqual(left: string, right: string): boolean {
  const leftBytes = encoder.encode(left);
  const rightBytes = encoder.encode(right);
  const length = Math.max(leftBytes.length, rightBytes.length);
  let mismatch = leftBytes.length ^ rightBytes.length;
  for (let index = 0; index < length; index += 1) {
    mismatch |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }
  return mismatch === 0;
}

function redactValue(value: unknown, secret: string, depth: number): unknown {
  if (depth > 8) return null;
  if (typeof value === "string") {
    return value.includes(secret) ? "[redacted]" : value;
  }
  if (value === null || typeof value === "number" || typeof value === "boolean") {
    return value;
  }
  if (Array.isArray(value)) {
    return value.map((entry) => redactValue(entry, secret, depth + 1));
  }
  if (typeof value !== "object") return null;

  const sanitized: JsonObject = {};
  for (const [key, child] of Object.entries(value as JsonObject)) {
    const normalizedKey = key.toLowerCase();
    if (
      normalizedKey === "secret" ||
      normalizedKey === "token" ||
      normalizedKey === "from" ||
      normalizedKey === "__proto__" ||
      normalizedKey === "constructor" ||
      normalizedKey === "prototype"
    ) {
      continue;
    }
    sanitized[key] = redactValue(child, secret, depth + 1);
  }
  return sanitized;
}

export function sanitizeForRelay(
  message: JsonObject & { type: ClientMessageType },
  secret: string,
  peerID: string,
): JsonObject {
  const sanitized = redactValue(message, secret, 0) as JsonObject;
  sanitized.type = message.type;
  sanitized.from = peerID;
  return sanitized;
}
