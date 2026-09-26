import { env } from "cloudflare:workers";
import { reset } from "cloudflare:test";
import { afterEach, expect, it, vi } from "vitest";
import worker from "../src/index";
import { verifyRelease } from "../src/companion-release";

// Public signature of the released 0.15.0 commit. No signing secret is used by the feed.
const release = { schema: 1, version: "0.15.0", commit: "904b473331a31367f04b18180aa0770b0a71536d",
  signature: "yOmmNudsSSmzNb1LZAtVqyZqggfJOknsLQ/E4eD32cIWTtZ3TPYqMTMDb4yphL3DeyVPy26UzaKIGaxXacV0Aw==" };
const request = () => worker.fetch(new Request("https://release.test/v1/companion-release"), env);
afterEach(async () => {
  await caches.default.delete("https://release.test/v1/companion-release");
  await reset(); vi.restoreAllMocks();
});
it("authenticates the public release and rejects a changed commit/version/signature", async () => {
  expect(await verifyRelease(release)).toEqual(release);
  for (const change of [{ commit: "b".repeat(40) }, { version: "0.16.0" }, { version: "0.16.0-beta" }, { signature: "A".repeat(86) + "==" }]) {
    await expect(verifyRelease({ ...release, ...change })).rejects.toThrow();
  }
});
it("serves and caches only a verified, bounded public manifest", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ ...release, instructions: "discard me" }));
  const response = await request();
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual(release);
  expect((await request()).status).toBe(200);
  expect(fetch).toHaveBeenCalledTimes(1);
  expect(fetch.mock.calls[0][0]).toBe("https://github.com/cyberculturedhq/hermes-jr-companion/releases/latest/download/companion-release.json");
});
it("never caches bad metadata or oversized chunked responses", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ ...release, commit: "c".repeat(40) }));
  expect((await request()).status).toBe(503);
  fetch.mockResolvedValue(new Response("x".repeat(4097)));
  expect((await request()).status).toBe(503);
  fetch.mockRejectedValue(new Error("offline"));
  expect((await request()).status).toBe(503);
  expect(await caches.default.match("https://release.test/v1/companion-release")).toBeUndefined();
});
