/** Public routing protocol. All application data inside binary records is opaque. */
export const PROTOCOL_VERSION = 1;
export const LIMITS = {
  jsonBytes: 4096,
  ciphertextBytes: 65_536,
  routingHeaderBytes: 16,
  devices: 16,
  managementPerMinute: 60,
  connectionsPerMinute: 30,
  framesPerMinute: 6000,
  bytesPerMinute: 128 * 1024 * 1024,
  bytesPerDay: 256 * 1024 * 1024,
  deviceFramesPerMinute: 3000,
  deviceBytesPerMinute: 64 * 1024 * 1024,
  pushesPerMinute: 30,
  pushesPerDay: 300,
  devicePushesPerMinute: 6,
} as const;

export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
export const TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
export const REFERENCE_PATTERN = /^[A-Za-z0-9_-]{32,64}$/;

export function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export function newToken(): string {
  return base64url(crypto.getRandomValues(new Uint8Array(32)));
}

export async function tokenHash(token: string): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token))));
}

export function bearer(request: Request): string | null {
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get("Authorization") ?? "");
  return match?.[1] ?? null;
}

/** Hashes are fixed length; avoid early-return string equality for bearer validation. */
export function sameHash(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left.charCodeAt(i) ^ right.charCodeAt(i);
  return diff === 0;
}

export function uuidBytes(id: string): Uint8Array {
  return Uint8Array.from(id.replace(/-/g, "").match(/.{2}/g)!, (pair) => Number.parseInt(pair, 16));
}

export function bytesUuid(bytes: Uint8Array): string {
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function routedRecord(deviceId: string, record: ArrayBuffer): ArrayBuffer {
  const frame = new Uint8Array(LIMITS.routingHeaderBytes + record.byteLength);
  frame.set(uuidBytes(deviceId));
  frame.set(new Uint8Array(record), LIMITS.routingHeaderBytes);
  return frame.buffer;
}
