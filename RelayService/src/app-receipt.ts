import { Buffer } from "node:buffer";
import { createPublicKey, timingSafeEqual, X509Certificate, sign } from "node:crypto";
import * as asn1 from "asn1js";
import { Certificate, ContentInfo, CryptoEngine, SignedData } from "pkijs";
import { APPLE_RECEIPT_ROOT_DER } from "./apple-root";
import { Attestation } from "./app-attest";
import { HttpError } from "./http";

const invalid = () => new HttpError(403, "app_verification_failed");
class WorkerCryptoEngine extends CryptoEngine {
  timingSafeEqual(a: ArrayBuffer | ArrayBufferView, b: ArrayBuffer | ArrayBufferView): boolean {
    return crypto.subtle.timingSafeEqual(a, b);
  }
}
const equal = (a: Buffer, b: Buffer) => a.length === b.length && timingSafeEqual(a, b);
const der = (bytes: Buffer) => {
  const value = asn1.fromBER(bytes);
  if (value.offset !== bytes.length || value.result.error) throw invalid();
  return value.result;
};
const spki = (key: string) => Buffer.from(createPublicKey(key).export({type: "spki", format: "der"}));

/** Verify the signed container before reading any risk or identity field. */
export async function verifyReceipt(receipt: Buffer, attestation: Attestation, env: Env, type: "ATTEST" | "RECEIPT"): Promise<number | null> {
  try {
    if (receipt.length > 16_384) throw invalid();
    const info = new ContentInfo({schema: der(receipt)});
    if (info.contentType !== "1.2.840.113549.1.7.2") throw invalid();
    const signed = new SignedData({schema: info.content});
    if (signed.signerInfos.length !== 1 || !signed.encapContentInfo.eContent) throw invalid();
    const root = new Certificate({schema: der(Buffer.from(APPLE_RECEIPT_ROOT_DER, "base64"))});
    const engine = new WorkerCryptoEngine({name: "worker", crypto});
    if (!await signed.verify({signer: 0, trustedCerts: [root], checkChain: true, extendedMode: false}, engine)) throw invalid();
    const payload = der(Buffer.from(signed.encapContentInfo.eContent.getValue()));
    if (!(payload instanceof asn1.Set) || payload.valueBlock.value.length > 32) throw invalid();
    const fields = new Map<number, Buffer>();
    for (const entry of payload.valueBlock.value) {
      if (!(entry instanceof asn1.Sequence) || entry.valueBlock.value.length !== 3) throw invalid();
      const [id, version, value] = entry.valueBlock.value;
      if (!(id instanceof asn1.Integer) || !(version instanceof asn1.Integer) || !(value instanceof asn1.OctetString) || fields.has(id.valueBlock.valueDec)) throw invalid();
      fields.set(id.valueBlock.valueDec, Buffer.from(value.getValue()));
    }
    const field = (id: number) => { const value = fields.get(id); if (!value) throw invalid(); return value; };
    const text = (id: number) => new TextDecoder("utf-8", {fatal: true, ignoreBOM: false}).decode(field(id));
    if (text(2) !== env.APP_ATTEST_APP_ID || text(6) !== type) throw invalid();
    const created = Date.parse(text(12));
    if (!Number.isFinite(created) || created < Date.now() - 300_000 || created > Date.now() + 60_000) throw invalid();
    const certificate = new X509Certificate(field(3));
    if (!equal(Buffer.from(certificate.publicKey.export({type: "spki", format: "der"})), spki(attestation.publicKey))) throw invalid();
    if (type === "ATTEST" && !equal(field(4), attestation.clientHash)) throw invalid();
    if (type === "ATTEST") return null;
    const risk = text(17);
    if (!/^[0-9]{1,6}$/.test(risk)) throw invalid();
    const expires = Date.parse(text(21));
    if (!Number.isFinite(expires) || expires <= Date.now()) throw invalid();
    return Number(risk);
  } catch { throw invalid(); }
}

/** Fresh key admission uses Apple's signed risk count. Existing key assertions stay local. */
export async function assessAttestation(attestation: Attestation, env: Env): Promise<void> {
  await verifyReceipt(attestation.receipt, attestation, env, "ATTEST");
  if (!env.APP_ATTEST_FRAUD_KEY_ID || !env.APP_ATTEST_FRAUD_PRIVATE_KEY) throw new HttpError(503, "app_verification_unavailable");
  const cap = Number(env.APP_ATTEST_MAX_KEYS ?? "5");
  if (!Number.isInteger(cap) || cap < 1 || cap > 20) throw new HttpError(503, "app_verification_unavailable");
  const encode = (data: unknown) => Buffer.from(JSON.stringify(data)).toString("base64url");
  const unsigned = `${encode({alg: "ES256", kid: env.APP_ATTEST_FRAUD_KEY_ID})}.${encode({iss: env.APP_ATTEST_APP_ID.split(".")[0], iat: Math.floor(Date.now()/1000)})}`;
  let jwt: string;
  try {
    jwt = unsigned + "." + sign("sha256", Buffer.from(unsigned), {key: env.APP_ATTEST_FRAUD_PRIVATE_KEY.replace(/\\n/g, "\n"), dsaEncoding: "ieee-p1363"}).toString("base64url");
  } catch { throw new HttpError(503, "app_verification_unavailable"); }
  const origin = env.APP_ATTEST_ENVIRONMENT === "development" ? "https://data-development.appattest.apple.com" : "https://data.appattest.apple.com";
  let response: Response;
  try {
    response = await fetch(origin + "/v1/attestationData", {method: "POST", redirect: "manual", signal: AbortSignal.timeout(8000), headers: {authorization: jwt, "content-type": "application/octet-stream"}, body: attestation.receipt.toString("base64")});
  } catch { throw new HttpError(503, "app_verification_unavailable"); }
  if (response.status !== 200) { await response.body?.cancel(); throw new HttpError(503, "app_verification_unavailable"); }
  const reader = response.body?.getReader();
  if (!reader) throw invalid();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > 24_576) throw invalid();
      chunks.push(value);
    }
  } finally { try { await reader.cancel(); } catch {} reader.releaseLock(); }
  const encoded = Buffer.concat(chunks).toString("ascii").trim();
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) throw invalid();
  const risk = await verifyReceipt(Buffer.from(encoded, "base64"), attestation, env, "RECEIPT");
  if (risk === null || risk > cap) throw new HttpError(429, "app_verification_key_limit");
}
