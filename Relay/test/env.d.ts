import type { Room } from "../src/room";

declare module "cloudflare:workers" {
  interface ProvidedEnv {
    ROOMS: DurableObjectNamespace<Room>;
    ROOM_CREATION_LIMITER: RateLimit;
    ROOM_CONNECT_LIMITER: RateLimit;
    ROOM_TTL_SECONDS: string;
  }
}
