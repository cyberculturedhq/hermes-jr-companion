import { failure } from "./http";

const repository = "cyberculturedhq/hermes-jr-companion";
const publicKey = "ac072d31db546d1f241ac1ace40cb0b474bd4e833d78385cb9f03499e44778af";
export type CompanionRelease = { schema: 1; version: string; commit: string; signature: string };

export async function verifyRelease(value: unknown): Promise<CompanionRelease> {
  const v = value as CompanionRelease;
  if (!v || typeof v !== "object" || Array.isArray(v) || Object.keys(v).sort().join(",") !== "commit,schema,signature,version" || v.schema !== 1 || typeof v.version !== "string" || v.version.length > 32
    || !/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(v.version)
    || typeof v.commit !== "string" || !/^[0-9a-f]{40}$/.test(v.commit)
    || typeof v.signature !== "string" || !/^[A-Za-z0-9+/]{86}==$/.test(v.signature)) throw new Error("invalid_release");
  const key = await crypto.subtle.importKey("raw", Uint8Array.from(publicKey.match(/../g)!, x => parseInt(x, 16)), "Ed25519", false, ["verify"]);
  const message = new TextEncoder().encode(`hermes-jr-release-v1\n${repository}\n${v.version}\n${v.commit}\n`);
  if (!await crypto.subtle.verify("Ed25519", key, Uint8Array.from(atob(v.signature), c => c.charCodeAt(0)), message)) throw new Error("invalid_signature");
  return { schema: 1, version: v.version, commit: v.commit, signature: v.signature };
}

export const releaseObject = "latest.json";

export async function storedRelease(bucket: R2Bucket): Promise<{ release: CompanionRelease; etag: string } | null> {
  const object = await bucket.get(releaseObject);
  if (!object) return null;
  if (object.size > 4096) { await object.body.cancel(); throw new Error("release_too_large"); }
  return { release: await verifyRelease(JSON.parse(await object.text())), etag: object.httpEtag };
}

/** R2 is the persistent source. Routine checks never contact GitHub. */
export async function companionRelease(bucket: R2Bucket): Promise<Response> {
  try {
    const stored = await storedRelease(bucket);
    if (!stored) return failure(503, "release_unavailable");
    return Response.json(stored.release, { headers: {
      "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "X-Hermes-Jr-Feed-Source": "r2",
    } });
  } catch { return failure(503, "release_unavailable"); }
}
