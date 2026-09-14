import { base64url } from "./protocol";
import { DurableObject } from "cloudflare:workers";

export type EncryptedNotification = { v: 1; kid: string; data: string };

export type PushEnvironment = "sandbox" | "production";
export type PushStatus = "accepted" | "unregistered" | "unavailable" | "failed";
export type PushStage = "signing" | "transport" | "apns";
// Only fixed Apple reason identifiers may cross the provider boundary. Unknown future
// reasons remain null; no response text, headers, identifiers, or exceptions are retained.
const APNS_REASONS = [
  "BadCollapseId", "BadDeviceToken", "BadExpirationDate", "BadMessageId", "BadPriority", "BadTopic",
  "DeviceTokenNotForTopic", "DuplicateHeaders", "IdleTimeout", "MissingDeviceToken", "MissingTopic",
  "PayloadEmpty", "TopicDisallowed", "BadCertificate", "BadCertificateEnvironment", "ExpiredProviderToken",
  "Forbidden", "InvalidProviderToken", "MissingProviderToken", "BadEnvironmentKeyIdInToken", "UnrelatedKeyIdInToken",
  "BadPath", "MethodNotAllowed", "Unregistered",
  "PayloadTooLarge", "TooManyProviderTokenUpdates", "TooManyRequests", "InternalServerError", "ServiceUnavailable", "Shutdown",
] as const;
export type APNsReason = typeof APNS_REASONS[number];
export type PushResult = { status: PushStatus; stage: PushStage | null; apns_status: number | null; reason: APNsReason | null };

/** Read the small provider error response under a hard cap, including chunked bodies. */
async function appleReason(response: Response): Promise<APNsReason | null> {
  const reader = response.body?.getReader();
  if (!reader) return null;
  const bytes = new Uint8Array(1024);
  let count = 0;
  let complete = false;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) { complete = true; break; }
      if (count + value.byteLength > bytes.byteLength) return null;
      bytes.set(value, count);
      count += value.byteLength;
    }
    const body: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes.subarray(0, count)));
    const reason = body && typeof body === "object" && "reason" in body ? body.reason : undefined;
    return APNS_REASONS.find((allowed) => reason === allowed) ?? null;
  } catch { return null; }
  finally {
    if (!complete) {
      try { await reader.cancel(); } catch { /* Cancellation must not hide an observed APNs status. */ }
    }
    reader.releaseLock();
  }
}

export function pushAvailable(env: Env): boolean {
  return Boolean(env.APNS_TEAM_ID && env.APNS_KEY_ID && env.APNS_TOPIC && env.APNS_PRIVATE_KEY
    && ["both", "sandbox", "production"].includes(env.APNS_ENVIRONMENT));
}

export function pushEnvironmentAllowed(env: Env, environment: PushEnvironment): boolean {
  return env.APNS_ENVIRONMENT === "both" || env.APNS_ENVIRONMENT === environment;
}

async function providerToken(env: Env): Promise<string> {
  const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const header = encode({ alg: "ES256", kid: env.APNS_KEY_ID });
  const claims = encode({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) });
  const unsigned = `${header}.${claims}`;
  const pem = env.APNS_PRIVATE_KEY.replace(/\\n/g, "\n").replace(/-----[A-Z ]+-----/g, "").replace(/\s/g, "");
  const der = Uint8Array.from(atob(pem), (character) => character.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(unsigned));
  return `${unsigned}.${base64url(new Uint8Array(signature))}`;
}

/** APNs credentials form one coordination atom per signing key. This internal object shares
 * a 30-minute provider JWT across installations and preserves it through hibernation.
 * Only the derived, expiring token is stored; the .p8 signing key stays in env secrets. */
export class APNsProviderToken extends DurableObject<Env> {
  private refreshing?: Promise<string>;

  async getToken(): Promise<string> {
    if (this.refreshing) return this.refreshing;
    const refresh = async () => {
      const cached = await this.ctx.storage.get<{ jwt: string; refreshAt: number }>("token");
      if (cached && cached.refreshAt > Date.now()) return cached.jwt;
      const jwt = await providerToken(this.env);
      await this.ctx.storage.put("token", { jwt, refreshAt: Date.now() + 30 * 60_000 });
      return jwt;
    };
    this.refreshing = refresh();
    try { return await this.refreshing; }
    finally { this.refreshing = undefined; }
  }
}

/** Fixed APNs hosts and topic. Clients cannot supply endpoints, text, or APNs credentials. */
export async function sendPush(env: Env, token: string, environment: PushEnvironment, reference: string, encrypted?: EncryptedNotification): Promise<PushResult> {
  return deliverPush(env, token, environment, reference, encrypted);
}

export async function sendSetupPush(env: Env, token: string, environment: PushEnvironment, intent: string, expires: number): Promise<PushResult> {
  return deliverPush(env, token, environment, intent, undefined, expires);
}

async function deliverPush(env: Env, token: string, environment: PushEnvironment, reference: string, encrypted?: EncryptedNotification, setupExpires?: number): Promise<PushResult> {
  if (!pushAvailable(env) || !pushEnvironmentAllowed(env, environment)) {
    return { status: "unavailable", stage: null, apns_status: null, reason: null };
  }
  let jwt: string;
  try {
    jwt = await env.APNS_AUTH.getByName(`${env.APNS_TEAM_ID}:${env.APNS_KEY_ID}`).getToken();
  } catch { return { status: "failed", stage: "signing", apns_status: null, reason: null }; }
  let response: Response;
  try {
    const origin = environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
    response = await fetch(`${origin}/3/device/${token}`, {
      method: "POST",
      redirect: "manual",
      signal: AbortSignal.timeout(8000),
      headers: {
        authorization: `bearer ${jwt}`,
        "content-type": "application/json",
        "apns-topic": env.APNS_TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(setupExpires ?? Math.floor(Date.now() / 1000) + 3600),
        "apns-collapse-id": setupExpires ? "hermes-jr-setup" : "hermes-jr-update",
      },
      body: JSON.stringify({
        aps: { alert: { title: "Hermes Jr.", body: setupExpires ? "Hermes is ready. Open the app to compare your pairing codes." : "You have a new notification. Open the app for details." }, sound: "default", ...(encrypted ? { "mutable-content": 1 } : {}) },
        ...(setupExpires ? { pairing_ready: reference } : { reference }),
        ...(encrypted ? { encrypted } : {}),
      }),
    });
  } catch { return { status: "failed", stage: "transport", apns_status: null, reason: null }; }
  // Workers supports manual/follow only. Never forward the provider credential or
  // device token to a Location supplied by a redirect response.
  if (response.status >= 300 && response.status < 400) {
    try { await response.body?.cancel(); } catch { /* No redirect target is contacted. */ }
    return { status: "failed", stage: "transport", apns_status: null, reason: null };
  }
  // Once response headers arrived, preserve that result even if its body cannot be read.
  // A transport failure has an unknown delivery outcome; it must never imply rejection.
  const status = response.status === 200 ? "accepted" : response.status === 410 ? "unregistered" : "failed";
  let reason: APNsReason | null = null;
  if (response.status === 200) {
    try { await response.body?.cancel(); } catch { /* Success is already confirmed. */ }
  } else reason = await appleReason(response);
  return { status, stage: "apns", apns_status: response.status, reason };
}
