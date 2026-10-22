import type { ReleaseFeedEnv } from "../release-feed-configuration";
import { companionRelease, releaseObject, storedRelease, verifyRelease, type CompanionRelease } from "./companion-release";
import { failure, handleErrors, json, readJson } from "./http";
import { bearer, sameHash, tokenHash } from "./protocol";

function compare(left: string, right: string): number {
  const a = left.split(".").map(BigInt), b = right.split(".").map(BigInt);
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i] ? 1 : -1;
  return 0;
}

async function publish(request: Request, env: ReleaseFeedEnv): Promise<Response> {
  const token = bearer(request);
  if (!token || !env.RELEASE_PUBLISH_TOKEN || !sameHash(await tokenHash(token), await tokenHash(env.RELEASE_PUBLISH_TOKEN)))
    return failure(401, "unauthorized");
  let candidate: CompanionRelease;
  const body = await readJson(request, 4096);
  try { candidate = await verifyRelease(body); }
  catch { return failure(400, "invalid_release"); }
  try {
    const current = await storedRelease(env.COMPANION_RELEASES);
    if (current) {
      const order = compare(candidate.version, current.release.version);
      if (order < 0) return json({ published: false, version: current.release.version });
      if (order === 0) {
        if (JSON.stringify(candidate) !== JSON.stringify(current.release)) return failure(409, "release_conflict");
        return json({ published: false, version: current.release.version });
      }
    }
    // A concurrent publisher cannot replace a newer release with an older one.
    const condition = new Headers(current ? { "If-Match": current.etag } : { "If-None-Match": "*" });
    const saved = await env.COMPANION_RELEASES.put(releaseObject, JSON.stringify(candidate), {
      onlyIf: condition, httpMetadata: { contentType: "application/json" },
    });
    if (!saved) return failure(409, "publication_race");
    return json({ published: true, version: candidate.version });
  } catch { return failure(503, "release_storage_unavailable"); }
}

// This route owns only release metadata. It has no pairing, relay, or Apple bindings.
export default {
  async fetch(request, env): Promise<Response> {
    return handleErrors(async () => {
      const url = new URL(request.url);
      if (url.protocol !== "https:" && !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) return failure(400, "https_required");
      if (url.search || request.headers.has("Origin")) return failure(400, "unsupported_request");
      const read = url.pathname === "/v1/companion-release" && request.method === "GET";
      const write = url.pathname === "/v1/companion-release/publish" && request.method === "POST";
      if (!read && !write) return failure(404, "not_found");
      const ip = request.headers.get("CF-Connecting-IP") ?? "unidentified";
      if (!(await env.REQUEST_RATE_LIMITER.limit({ key: `release:${ip}` })).success) return failure(429, "rate_limited");
      return read ? companionRelease(env.COMPANION_RELEASES) : publish(request, env);
    });
  },
} satisfies ExportedHandler<ReleaseFeedEnv>;
