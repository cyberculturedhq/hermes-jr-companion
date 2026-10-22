import { env } from "cloudflare:workers";
import { reset } from "cloudflare:test";
import { afterEach, expect, it, vi } from "vitest";
import worker from "../src/index";
import feed from "../src/release-feed";
import { releaseObject, verifyRelease } from "../src/companion-release";

// Public release signatures. No private signing key is used by the service.
const release = { schema: 1, version: "0.15.0", commit: "904b473331a31367f04b18180aa0770b0a71536d",
  signature: "yOmmNudsSSmzNb1LZAtVqyZqggfJOknsLQ/E4eD32cIWTtZ3TPYqMTMDb4yphL3DeyVPy26UzaKIGaxXacV0Aw==" };
const newer = { schema: 1, version: "0.19.1", commit: "3f14aa702d9f726fa7947daa8670256e0df42bfa",
  signature: "mW9tweQnSw84m7LdsFLtzYQWqyKhD2/C1V0AvkLriMdSttNabCkfCBdEezBPCJ9H1bywze6CnApsvxtUpq0eDA==" };
const token = "t".repeat(43);
const feedEnv = () => ({ ...env, RELEASE_PUBLISH_TOKEN: token });
const request = () => worker.fetch(new Request("https://release.test/v1/companion-release"), env);
const publish = (body: unknown, auth = token) => feed.fetch(new Request("https://release.test/v1/companion-release/publish", {
  method: "POST", headers: { "Content-Type": "application/json", "Authorization": `Bearer ${auth}` }, body: JSON.stringify(body),
}), feedEnv());
afterEach(async () => { await reset(); vi.restoreAllMocks(); });
it("authenticates the release and rejects changed fields or extra fields", async () => {
  expect(await verifyRelease(release)).toEqual(release);
  for (const change of [{ commit: "b".repeat(40) }, { version: "0.16.0" }, { version: "0.16.0-beta" }, { signature: "A".repeat(86) + "==" }, { url: "https://evil.test" }])
    await expect(verifyRelease({ ...release, ...change })).rejects.toThrow();
});
it("serves persistent signed metadata with no GitHub request or stale edge cache", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("GitHub unavailable"));
  await env.COMPANION_RELEASES.put(releaseObject, JSON.stringify(release));
  expect(await (await request()).json()).toEqual(release);
  await env.COMPANION_RELEASES.put(releaseObject, JSON.stringify(newer));
  const response = await request();
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual(newer);
  expect(response.headers.get("X-Hermes-Jr-Feed-Source")).toBe("r2");
  expect(fetch).not.toHaveBeenCalled();
});
it("fails closed for missing, tampered or oversized stored metadata", async () => {
  expect((await request()).status).toBe(503);
  for (const value of [JSON.stringify({ ...release, commit: "c".repeat(40) }), "x".repeat(4097)]) {
    await env.COMPANION_RELEASES.put(releaseObject, value);
    const result = await request();
    expect(result.status).toBe(503);
    expect(result.headers.get("Cache-Control")).toBe("no-store");
  }
});
it("requires publisher authentication and signature before changing the record", async () => {
  expect((await publish(release, "bad")).status).toBe(401);
  expect((await publish({ ...release, version: "9.0.0" })).status).toBe(400);
  expect((await publish({ ...release, padding: "x".repeat(4096) })).status).toBe(413);
  expect(await env.COMPANION_RELEASES.get(releaseObject)).toBeNull();
});
it("publishes idempotently and never downgrades on an old release event", async () => {
  expect(await (await publish(release)).json()).toEqual({ published: true, version: release.version });
  expect(await (await publish(release)).json()).toEqual({ published: false, version: release.version });
  expect((await publish(newer)).status).toBe(200);
  expect(await (await publish(release)).json()).toEqual({ published: false, version: newer.version });
  expect(await (await request()).json()).toEqual(newer);
});
it("uses a conditional write so concurrent publishers cannot roll back the feed", async () => {
  const results = await Promise.all([publish(release), publish(newer)]);
  expect(results.map(r => r.status).every(status => [200,409].includes(status))).toBe(true);
  // Retry a conflict from the newer publisher, as the CI publisher does.
  expect((await publish(newer)).status).toBe(200);
  expect(await (await request()).json()).toEqual(newer);
});
it("does not claim unrelated relay routes or accept browser requests", async () => {
  for (const path of ["/health", "/v1/companion-release/other", "/v1/companion-release?url=evil"]) {
    const result = await feed.fetch(new Request("https://release.test" + path), feedEnv());
    expect([400,404]).toContain(result.status);
  }
  expect((await feed.fetch(new Request("https://release.test/v1/companion-release", { headers: { Origin: "https://evil.test" } }), feedEnv())).status).toBe(400);
});
