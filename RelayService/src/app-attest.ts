import { createHash, timingSafeEqual, verify, X509Certificate, createPublicKey } from "node:crypto";
import { Buffer } from "node:buffer";
import { APPLE_APP_ATTEST_ROOT } from "./apple-root";
import { HttpError } from "./http";
import { unbase64 } from "./setup-ticket";

type Cbor = number | string | Buffer | Map<Cbor, Cbor> | Cbor[];
const invalid = () => new HttpError(403, "app_verification_failed");
const hash = (data: Uint8Array | string) => createHash("sha256").update(data).digest();
const equal = (a: Uint8Array, b: Uint8Array) => a.length === b.length && timingSafeEqual(a, b);

/** Bounded, definite-length CBOR. Reject duplicate keys, tags, trailing bytes, and excessive nesting. */
function decode(bytes: Buffer, start = 0): { value: Cbor; end: number } {
  let offset = start;
  function read(depth: number): Cbor {
    if (depth > 6 || offset >= bytes.length) throw invalid();
    const head = bytes[offset++];
    const major = head >> 5, small = head & 31;
    let size = small;
    if (small >= 24) {
      const width = small === 24 ? 1 : small === 25 ? 2 : small === 26 ? 4 : 0;
      if (!width || offset + width > bytes.length) throw invalid();
      size = bytes.readUIntBE(offset, width); offset += width;
    }
    if (major === 0) return size;
    if (major === 1) return -1 - size;
    if (major === 2 || major === 3) {
      if (size > bytes.length - offset) throw invalid();
      const value = bytes.subarray(offset, offset + size); offset += size;
      return major === 2 ? value : new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(value);
    }
    if (major === 4) {
      if (size > 32) throw invalid();
      return Array.from({length:size},()=>read(depth+1));
    }
    if (major === 5) {
      if (size > 32) throw invalid();
      const map = new Map<Cbor, Cbor>();
      for (let i = 0; i < size; i++) {
        const key = read(depth + 1);
        if ((typeof key !== "string" && typeof key !== "number") || map.has(key)) throw invalid();
        map.set(key, read(depth + 1));
      }
      return map;
    }
    throw invalid();
  }
  const value = read(0);
  return { value, end: offset };
}
function map(value: Cbor | undefined): Map<Cbor, Cbor> {
  if (!(value instanceof Map)) throw invalid();
  return value;
}
function bytes(value: Cbor | undefined): Buffer {
  if (!Buffer.isBuffer(value)) throw invalid();
  return value;
}
function object(encoded: string): Map<Cbor, Cbor> {
  const raw = Buffer.from(unbase64(encoded));
  if (raw.length > 24_576) throw invalid();
  const parsed = decode(raw);
  if (parsed.end !== raw.length) throw invalid();
  return map(parsed.value);
}

/** Strict DER walk used only to locate Apple's nonce certificate extension. */
function nonceExtension(raw: Buffer): Buffer {
  const oid = Buffer.from("2a864886f763640802", "hex"); // 1.2.840.113635.100.8.2
  let found: Buffer | undefined;
  function walk(data: Buffer, depth: number): void {
    if (depth > 12) throw invalid();
    let offset = 0;
    const nodes: { tag: number; value: Buffer }[] = [];
    while (offset < data.length) {
      const tag = data[offset++];
      let length = data[offset++];
      if (length === undefined) throw invalid();
      if (length & 128) {
        const width = length & 127;
        if (!width || width > 4 || offset + width > data.length) throw invalid();
        length = data.readUIntBE(offset, width); offset += width;
      }
      if (length > data.length - offset) throw invalid();
      nodes.push({ tag, value: data.subarray(offset, offset + length) }); offset += length;
    }
    if (nodes[0]?.tag === 6 && equal(nodes[0].value, oid)) {
      const extension = nodes[nodes.length - 1];
      if (extension.tag !== 4 || found) throw invalid();
      // Apple's extension is SEQUENCE { [1] { OCTET STRING nonce } }.
      const expectedPrefix = Buffer.from([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]);
      if (extension.value.length !== 38 || !equal(extension.value.subarray(0, 6), expectedPrefix)) throw invalid();
      found = extension.value.subarray(6);
    }
    for (const node of nodes) if (node.tag & 32) walk(node.value, depth + 1);
  }
  walk(raw, 0);
  if (!found) throw invalid();
  return found;
}

export function admissionData(origin: string, challenge: string, keyId: string, phoneKey: string): string {
  return `hermes-jr/admission/v1\n${origin}\n${challenge}\n${keyId}\n${phoneKey}\n`;
}

function authenticator(data: Buffer, env: Env, offset: number, enforceDistribution = true): number {
  if (!env.APP_ATTEST_APP_ID || data.length < 37 || !equal(data.subarray(0, 32), hash(env.APP_ATTEST_APP_ID))) throw invalid();
  // New OS versions include distribution metadata. Reject nonofficial distribution when supplied.
  if ((data[32] & 128) || offset < data.length) {
    const parsed = decode(data, offset);
    if (parsed.end !== data.length) throw invalid();
    const extensions = map(parsed.value);
    const category = extensions.get("apple_validation_category_01") ?? extensions.get("validationCategory");
    const version = extensions.get("apple_bundle_version_01") ?? extensions.get("bundleVersion");
    const allowed = env.APP_ATTEST_ENVIRONMENT === "development" ? [3] : [2, 4];
    const categoryNumber = Buffer.isBuffer(category) && category.length === 4 ? category.readUInt32LE() : category;
    if (enforceDistribution && category !== undefined && !allowed.includes(Number(categoryNumber))) throw invalid();
    if (version !== undefined && (typeof version !== "string" || !/^\d+(?:\.\d+)*$/.test(version))) throw invalid();
  } else if (offset !== data.length) throw invalid();
  return data.readUInt32BE(33);
}

export type Attestation = { publicKey: string; receipt: Buffer; clientHash: Buffer };

// The separate digest input permits checks against Apple's published cryptographic test vector.
export function attestationDetails(encoded: string, keyId: string, clientHash: Buffer, env: Env, enforceDistribution = true): Attestation {
  try {
    const value = object(encoded);
    if (value.get("fmt") !== "apple-appattest") throw invalid();
    const statement = map(value.get("attStmt")), chain = statement.get("x5c");
    if (!Array.isArray(chain) || chain.length !== 2) throw invalid();
    const leaf = new X509Certificate(bytes(chain[0]));
    const intermediate = new X509Certificate(bytes(chain[1]));
    const root = new X509Certificate(APPLE_APP_ATTEST_ROOT);
    for (const cert of [leaf, intermediate, root]) {
      if (Date.parse(cert.validFrom) > Date.now() || Date.parse(cert.validTo) <= Date.now()) throw invalid();
    }
    if (leaf.ca || !intermediate.ca || !leaf.checkIssued(intermediate) || !intermediate.checkIssued(root)
      || !leaf.verify(intermediate.publicKey) || !intermediate.verify(root.publicKey)) throw invalid();
    const auth = bytes(value.get("authData"));
    if (auth.length < 87 || !(auth[32] & 64) || auth.readUInt16BE(53) !== 32) throw invalid();
    const publicKey = leaf.publicKey.export({ format: "jwk" });
    if (publicKey.kty !== "EC" || publicKey.crv !== "P-256" || !publicKey.x || !publicKey.y) throw invalid();
    const point = Buffer.concat([Buffer.from([4]), Buffer.from(publicKey.x, "base64url"), Buffer.from(publicKey.y, "base64url")]);
    const identifier = Buffer.from(unbase64(keyId));
    if (!equal(hash(point), identifier) || !equal(auth.subarray(55, 87), identifier)) throw invalid();
    const aaguid = env.APP_ATTEST_ENVIRONMENT === "development" ? Buffer.from("appattestdevelop") : Buffer.concat([Buffer.from("appattest"), Buffer.alloc(7)]);
    if (!equal(auth.subarray(37, 53), aaguid)) throw invalid();
    const cose = decode(auth, 87), key = map(cose.value);
    if (key.get(1) !== 2 || key.get(3) !== -7 || key.get(-1) !== 1
      || !equal(bytes(key.get(-2)), point.subarray(1, 33)) || !equal(bytes(key.get(-3)), point.subarray(33))) throw invalid();
    if (authenticator(auth, env, cose.end, enforceDistribution) !== 0) throw invalid();
    const nonce = hash(Buffer.concat([auth, clientHash]));
    if (!equal(nonceExtension(leaf.raw), nonce)) throw invalid();
    return { publicKey: leaf.publicKey.export({ format: "pem", type: "spki" }).toString(), receipt: bytes(statement.get("receipt")), clientHash };
  } catch { throw invalid(); }
}

export function verifyAttestation(encoded: string, keyId: string, clientData: string, env: Env): Attestation {
  return attestationDetails(encoded, keyId, hash(clientData), env);
}

export function verifyAssertion(encoded: string, publicKey: string, previous: number, clientData: string, env: Env): number {
  try {
    const value = object(encoded), auth = bytes(value.get("authenticatorData")), signature = bytes(value.get("signature"));
    if (auth.length < 37 || (auth[32] & 64)) throw invalid();
    const counter = authenticator(auth, env, 37);
    if (counter <= previous || !verify("sha256", Buffer.concat([auth, hash(clientData)]), createPublicKey(publicKey), signature)) throw invalid();
    return counter;
  } catch { throw invalid(); }
}
