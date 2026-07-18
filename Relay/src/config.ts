export const MAX_PEERS = 8;
export const MAX_PENDING_CONNECTIONS = MAX_PEERS * 2;
export const MAX_FRAME_BYTES = 16 * 1024;
export const HELLO_TIMEOUT_MS = 10_000;
export const RATE_LIMIT_WINDOW_MS = 10_000;
export const RATE_LIMIT_MESSAGES = 60;
export const DEFAULT_ROOM_TTL_SECONDS = 24 * 60 * 60;
export const MIN_ROOM_TTL_SECONDS = 60;
export const MAX_ROOM_TTL_SECONDS = 7 * 24 * 60 * 60;

export function roomTtlMilliseconds(rawValue: string | undefined): number {
  const value = Number(rawValue ?? DEFAULT_ROOM_TTL_SECONDS);
  const seconds = Number.isFinite(value)
    ? Math.min(MAX_ROOM_TTL_SECONDS, Math.max(MIN_ROOM_TTL_SECONDS, value))
    : DEFAULT_ROOM_TTL_SECONDS;
  return Math.floor(seconds * 1_000);
}
