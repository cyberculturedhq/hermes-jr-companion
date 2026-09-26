import { base64url, newToken, TOKEN_PATTERN } from "./protocol";
import { HttpError } from "./http";

export type SetupTicket = { intent_id: string; phone_public_key: string; expires_at: number; service: string };
export function unbase64(value: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new HttpError(400, "invalid_encoding");
  let bytes: Uint8Array<ArrayBuffer>;
  try { bytes = Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0)); }
  catch { throw new HttpError(400, "invalid_encoding"); }
  if (base64url(bytes) !== value) throw new HttpError(400, "invalid_encoding");
  return bytes;
}
export function key32(value: unknown): value is string {
  return typeof value === "string" && TOKEN_PATTERN.test(value) && unbase64(value).length === 32;
}
async function signingKey(env: Env): Promise<CryptoKey> {
  if (!env.SETUP_TICKET_PRIVATE_KEY) throw new HttpError(503, "pairing_unavailable");
  return crypto.subtle.importKey("pkcs8", unbase64(env.SETUP_TICKET_PRIVATE_KEY), { name: "Ed25519" }, true, ["sign"]);
}
export async function setupPublicKey(env: Env): Promise<string> {
  const key = await crypto.subtle.exportKey("jwk", await signingKey(env));
  if (!("x" in key) || !key.x) throw new Error("Invalid signing key");
  return key.x;
}
export async function issueTicket(env: Env, phoneKey: string, service: string): Promise<{ ticket: string; intent: SetupTicket }> {
  const issued = Math.floor(Date.now() / 1000);
  const intent = { intent_id: newToken(), phone_public_key: phoneKey, expires_at: issued + 1200, service };
  const payload = base64url(new TextEncoder().encode(JSON.stringify([1, intent.intent_id, phoneKey, issued, intent.expires_at, service])));
  const signed = `HJ1.${payload}`;
  const signature = await crypto.subtle.sign("Ed25519", await signingKey(env), new TextEncoder().encode(signed));
  return { ticket: `${signed}.${base64url(new Uint8Array(signature))}`, intent };
}
export async function verifyTicket(env: Env, ticket: string, service: string): Promise<SetupTicket> {
  if (ticket.length > 2048) throw new HttpError(400, "invalid_ticket");
  const [prefix, payload, signature, extra] = ticket.split(".");
  if (prefix !== "HJ1" || !payload || !signature || extra !== undefined) throw new HttpError(400, "invalid_ticket");
  const key = await crypto.subtle.importKey("raw", unbase64(await setupPublicKey(env)), "Ed25519", false, ["verify"]);
  if (!await crypto.subtle.verify("Ed25519", key, unbase64(signature), new TextEncoder().encode(`HJ1.${payload}`))) throw new HttpError(401, "invalid_ticket");
  let value: unknown;
  try { value = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(unbase64(payload))); }
  catch { throw new HttpError(400, "invalid_ticket"); }
  if (!Array.isArray(value) || value.length !== 6) throw new HttpError(400, "invalid_ticket");
  const [v, id, phone, issued, expires, origin] = value;
  const now = Date.now() / 1000;
  if (v !== 1 || !key32(id) || !key32(phone) || !Number.isSafeInteger(issued) || !Number.isSafeInteger(expires)
    || issued > now + 30 || expires <= now || expires > issued + 1200 || origin !== service) throw new HttpError(410, "invalid_or_expired_ticket");
  return { intent_id: id, phone_public_key: phone, expires_at: expires, service: origin };
}
