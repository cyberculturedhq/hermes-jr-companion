import { failure } from "./http";

const repository = "cyberculturedhq/hermes-jr-companion";
const publicKey = "ac072d31db546d1f241ac1ace40cb0b474bd4e833d78385cb9f03499e44778af";
export type CompanionRelease = { schema: 1; version: string; commit: string; signature: string };

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
    const response = await fetch(`https://github.com/${repository}/releases/latest/download/companion-release.json`, {
      headers: { Accept: "application/json" }, signal: AbortSignal.timeout(8000),
    });
    if (!response.ok || !response.body || Number(response.headers.get("Content-Length") ?? 0) > 4096) throw new Error("release_unavailable");
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 4096) { await reader.cancel(); throw new Error("release_too_large"); }
        chunks.push(value);
      }
    } finally { reader.releaseLock(); }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const release = await verifyRelease(JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)));
    const result = Response.json(release, { headers: { "Cache-Control": "public, max-age=300", "X-Content-Type-Options": "nosniff" } });
    await caches.default.put(cacheKey, result.clone());
    return result;
  } catch { return failure(503, "release_unavailable"); }
}
