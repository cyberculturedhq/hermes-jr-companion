import { failure } from "./http";

const repository = "cyberculturedhq/hermes-jr-companion";
const api = `https://api.github.com/repos/${repository}`;
const publicKey = "ac072d31db546d1f241ac1ace40cb0b474bd4e833d78385cb9f03499e44778af";
export type CompanionRelease = { schema: 1; version: string; commit: string; signature: string };

async function githubJson(path: string, limit: number): Promise<any> {
  const response = await fetch(api + path, {
    headers: { Accept: "application/vnd.github+json", "User-Agent": "hermes-jr-companion-release-feed" },
    redirect: "error", signal: AbortSignal.timeout(8000),
  });
  if (!response.ok || !response.body || Number(response.headers.get("Content-Length") ?? 0) > limit)
    throw new Error("release_unavailable");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > limit) { await reader.cancel(); throw new Error("release_too_large"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
}

async function latestRelease(): Promise<CompanionRelease> {
  const release = await githubJson("/releases/latest", 128_000);
  const tag = release?.tag_name;
  if (release?.draft || release?.prerelease || typeof tag !== "string"
    || !/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(tag)
    || tag.length > 33) throw new Error("invalid_release");
  const matches = [...(release.body ?? "").matchAll(/<!-- hermes-jr-release-v1: ([A-Za-z0-9+/]{86}==) -->/g)];
  if (matches.length !== 1) throw new Error("invalid_signature");
  let object = (await githubJson(`/git/ref/tags/${tag}`, 4096))?.object;
  for (let depth = 0; depth < 3; depth++) {
    if (typeof object?.sha !== "string" || !/^[0-9a-f]{40}$/.test(object.sha)) throw new Error("invalid_commit");
    if (object.type === "commit")
      return verifyRelease({ schema: 1, version: tag.slice(1), commit: object.sha, signature: matches[0][1] });
    if (object.type !== "tag") throw new Error("invalid_tag");
    object = (await githubJson(`/git/tags/${object.sha}`, 4096))?.object;
  }
  throw new Error("too_many_tag_indirections");
}

export async function verifyRelease(value: unknown): Promise<CompanionRelease> {
  const v = value as CompanionRelease;
  if (!v || v.schema !== 1 || typeof v.version !== "string" || v.version.length > 32
    || !/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(v.version)
    || typeof v.commit !== "string" || !/^[0-9a-f]{40}$/.test(v.commit)
    || typeof v.signature !== "string" || !/^[A-Za-z0-9+/]{86}==$/.test(v.signature)) throw new Error("invalid_release");
  const key = await crypto.subtle.importKey("raw", Uint8Array.from(publicKey.match(/../g)!, x => parseInt(x, 16)), "Ed25519", false, ["verify"]);
  const message = new TextEncoder().encode(`hermes-jr-release-v1\n${repository}\n${v.version}\n${v.commit}\n`);
  if (!await crypto.subtle.verify("Ed25519", key, Uint8Array.from(atob(v.signature), c => c.charCodeAt(0)), message)) throw new Error("invalid_signature");
  return { schema: 1, version: v.version, commit: v.commit, signature: v.signature };
}

/** Fixed public source, bounded response, and no installation/device identifiers. */
export async function companionRelease(request: Request): Promise<Response> {
  const cacheKey = new Request(new URL("/v1/companion-release", request.url));
  const cached = await caches.default.match(cacheKey);
  if (cached) return cached;
  try {
    const release = await latestRelease();
    const result = Response.json(release, { headers: { "Cache-Control": "public, max-age=300", "X-Content-Type-Options": "nosniff" } });
    await caches.default.put(cacheKey, result.clone());
    return result;
  } catch { return failure(503, "release_unavailable"); }
}
