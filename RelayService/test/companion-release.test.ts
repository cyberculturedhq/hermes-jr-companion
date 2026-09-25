import { env } from "cloudflare:workers";
import { reset } from "cloudflare:test";
import { afterEach, expect, it, vi } from "vitest";
import worker from "../src/index";
import { verifyRelease } from "../src/companion-release";

// Public signature of the released 0.15.0 commit. No signing secret is used by the feed.
const release = { schema: 1, version: "0.15.0", commit: "904b473331a31367f04b18180aa0770b0a71536d",
  signature: "yOmmNudsSSmzNb1LZAtVqyZqggfJOknsLQ/E4eD32cIWTtZ3TPYqMTMDb4yphL3DeyVPy26UzaKIGaxXacV0Aw==" };
const api = "https://api.github.com/repos/cyberculturedhq/hermes-jr-companion";
const githubRelease = { tag_name: "v0.15.0", draft: false, prerelease: false,
  body: `Release notes\n<!-- hermes-jr-release-v1: ${release.signature} -->` };
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
it("serves and caches only a verified, bounded GitHub release", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockImplementation(async input => {
    if (input === `${api}/releases/latest`) return Response.json({ ...githubRelease, instructions: "discard me" });
    if (input === `${api}/git/ref/tags/v0.15.0`) return Response.json({ object: { type: "tag", sha: "a".repeat(40) } });
    if (input === `${api}/git/tags/${"a".repeat(40)}`) return Response.json({ object: { type: "commit", sha: release.commit } });
    throw new Error("unexpected URL");
  });
  const response = await request();
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual(release);
  expect((await request()).status).toBe(200);
  expect(fetch).toHaveBeenCalledTimes(3);
  expect(fetch.mock.calls[0][0]).toBe(`${api}/releases/latest`);
  expect(fetch.mock.calls[0][1]?.redirect).toBe("manual");
});
it("never caches a release with a changed commit, absent signature, or oversized response", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockImplementation(async input => {
    if (input === `${api}/releases/latest`) return Response.json(githubRelease);
    return Response.json({ object: { type: "commit", sha: "c".repeat(40) } });
  });
  expect((await request()).status).toBe(503);
  fetch.mockResolvedValue(Response.json({ ...githubRelease, body: "unsigned" }));
  expect((await request()).status).toBe(503);
  fetch.mockResolvedValue(new Response("x".repeat(128_001)));
  expect((await request()).status).toBe(503);
  fetch.mockRejectedValue(new Error("offline"));
  expect((await request()).status).toBe(503);
  expect(await caches.default.match("https://release.test/v1/companion-release")).toBeUndefined();
});
