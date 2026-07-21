import { describe, expect, it } from "vitest";
import { MAX_FRAME_BYTES, RATE_LIMIT_MESSAGES } from "../src/config";
import {
  constantTimeEqual,
  consumeRateLimit,
  parseClientFrame,
  sanitizeForRelay,
} from "../src/protocol";

describe("relay protocol", () => {
  it("allows only the documented client message types", () => {
    expect(parseClientFrame('{"type":"play","time":12}').ok).toBe(true);
    expect(parseClientFrame('{"type":"play","position":12}')).toEqual({
      ok: false,
      reason: "field_not_allowed",
    });
    expect(parseClientFrame('{"type":"welcome"}')).toEqual({
      ok: false,
      reason: "message_type_not_allowed",
    });
  });

  it("accepts reactions with an emoji name and nothing else", () => {
    expect(parseClientFrame('{"type":"react","name":"🍿"}').ok).toBe(true);
    expect(parseClientFrame('{"type":"react"}')).toEqual({
      ok: false,
      reason: "missing_required_field",
    });
    expect(parseClientFrame('{"type":"react","name":"🍿","time":3}')).toEqual({
      ok: false,
      reason: "field_not_allowed",
    });
  });

  it("validates the documented fields and finite playback values", () => {
    expect(parseClientFrame('{"type":"tick","time":null}')).toEqual({
      ok: false,
      reason: "invalid_time",
    });
    expect(parseClientFrame(JSON.stringify({ type: "hello", name: "x".repeat(257) }))).toEqual({
      ok: false,
      reason: "invalid_name",
    });
    for (const frame of [
      '{"type":"loaded"}',
      '{"type":"play"}',
      '{"type":"pause"}',
      '{"type":"tick"}',
      '{"type":"seek","time":12}',
    ]) {
      expect(parseClientFrame(frame)).toEqual({
        ok: false,
        reason: "missing_required_field",
      });
    }
    expect(parseClientFrame('{"type":"seek","time":12,"playing":true}').ok).toBe(true);
    expect(parseClientFrame(JSON.stringify({
      type: "loaded",
      name: "Episode 4",
      art: "https://images.example/poster.jpg",
      url: "https://www.netflix.com/watch/1234",
      time: 42,
      playing: true,
    })).ok).toBe(true);
    expect(parseClientFrame(JSON.stringify({
      type: "loaded", name: "bad", url: "javascript:alert(1)",
    }))).toEqual({ ok: false, reason: "invalid_url" });
    expect(parseClientFrame(JSON.stringify({
      type: "loaded", name: "bad", art: "file:///tmp/poster.png",
    }))).toEqual({ ok: false, reason: "invalid_art" });
  });

  it("rejects binary and frames larger than 16 KiB", () => {
    expect(parseClientFrame(new ArrayBuffer(1))).toEqual({
      ok: false,
      reason: "binary_not_supported",
    });
    const oversized = JSON.stringify({ type: "tick", value: "x".repeat(MAX_FRAME_BYTES) });
    expect(parseClientFrame(oversized)).toEqual({ ok: false, reason: "frame_too_large" });
  });

  it("overwrites from and recursively removes secrets", () => {
    const secret = "super-secret-value";
    const result = sanitizeForRelay(
      {
        type: "loaded",
        from: "attacker",
        secret,
        token: secret,
        nested: { from: "also-attacker", secret, token: secret, text: `contains ${secret}` },
      },
      secret,
      "server-peer",
    );
    expect(result).toEqual({
      type: "loaded",
      nested: { text: "[redacted]" },
      from: "server-peer",
    });
  });

  it("compares secrets without early exit and limits each fixed window", () => {
    expect(constantTimeEqual("same", "same")).toBe(true);
    expect(constantTimeEqual("same", "different")).toBe(false);
    const state = { windowStartedAt: 1_000, messages: 0 };
    for (let index = 0; index < RATE_LIMIT_MESSAGES; index += 1) {
      expect(consumeRateLimit(state, 1_001)).toBe(true);
    }
    expect(consumeRateLimit(state, 1_001)).toBe(false);
    expect(consumeRateLimit(state, 20_000)).toBe(true);
  });
});
