import { env } from "cloudflare:workers";
import { Buffer } from "node:buffer";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import { admissionData, attestationDetails, verifyAssertion, verifyAttestation } from "../src/app-attest";
import { assessAttestation, verifyReceipt } from "../src/app-receipt";
import vector from "./apple-attest-vector.json";

const hash = (data: Buffer | string) => createHash("sha256").update(data).digest();
const encodedVector = Buffer.from(vector.attestation, "base64").toString("base64url");
const keyId = Buffer.from(vector.key_id, "base64").toString("base64url");
const fixtureEnv = {...env, APP_ATTEST_APP_ID: "1234567890.com.example.myapp", APP_ATTEST_ENVIRONMENT: "production"};
function cbor(value: Buffer | string | Record<string, Buffer>): Buffer {
  const head = (major: number, size: number) => size < 24 ? Buffer.from([major * 32 + size]) : size < 256 ? Buffer.from([major * 32 + 24,size]) : Buffer.from([major * 32 + 25,size >> 8,size & 255]);
  if (typeof value === "string") return Buffer.concat([head(3,Buffer.byteLength(value)),Buffer.from(value)]);
  if (Buffer.isBuffer(value)) return Buffer.concat([head(2,value.length),value]);
  return Buffer.concat([head(5,Object.keys(value).length),...Object.entries(value).flatMap(([k,v]) => [cbor(k),cbor(v)])]);
}
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });
describe("Apple app verification", () => {
  it("checks Apple's published attestation and signed receipt with the pinned roots", async () => {
    vi.useFakeTimers(); vi.setSystemTime(new Date("2026-04-21T18:14:00Z"));
    // Apple publishes this value directly as the nonce digest input in its worked example.
    const attestation = attestationDetails(encodedVector,keyId,Buffer.from(vector.challenge),fixtureEnv,false);
    expect(attestation.publicKey).toContain("PUBLIC KEY");
    await expect(verifyReceipt(attestation.receipt,attestation,fixtureEnv,"ATTEST")).resolves.toBeNull();
    const changed = Buffer.from(attestation.receipt); changed[changed.length-30] ^= 1;
    await expect(verifyReceipt(changed,attestation,fixtureEnv,"ATTEST")).rejects.toThrow("app_verification_failed");
  });
  it("rejects an expired chain, wrong application, wrong key, nonce, distribution, or encoding", () => {
    expect(() => attestationDetails(encodedVector,keyId,Buffer.from(vector.challenge),fixtureEnv,false)).toThrow();
    vi.useFakeTimers(); vi.setSystemTime(new Date("2026-04-21T18:14:00Z"));
    for (const [id,digest,config] of [
      [keyId,Buffer.from("wrong"),fixtureEnv],
      [Buffer.alloc(32).toString("base64url"),Buffer.from(vector.challenge),fixtureEnv],
      [keyId,Buffer.from(vector.challenge),{...fixtureEnv,APP_ATTEST_APP_ID: "another.app"}],
    ] as const) expect(() => attestationDetails(encodedVector,id,digest,config,false)).toThrow();
    // The public vector uses category 1. The hosted app accepts App Store/TestFlight only.
    expect(() => attestationDetails(encodedVector,keyId,Buffer.from(vector.challenge),fixtureEnv)).toThrow();
    expect(() => verifyAttestation(encodedVector,keyId,vector.challenge,fixtureEnv)).toThrow();
    expect(() => attestationDetails(encodedVector + "AA",keyId,Buffer.from(vector.challenge),fixtureEnv,false)).toThrow();
  });
  it("binds assertions to the challenge, phone, origin, application, and increasing counter", () => {
    const key = generateKeyPairSync("ec",{namedCurve:"prime256v1"});
    const publicKey = key.publicKey.export({type:"spki",format:"pem"}).toString();
    const data = admissionData("https://relay.test","challenge","key","phone");
    const auth = Buffer.concat([hash(fixtureEnv.APP_ATTEST_APP_ID),Buffer.from([0,0,0,0,1])]);
    const signature = sign("sha256",Buffer.concat([auth,hash(data)]),key.privateKey);
    const proof = cbor({authenticatorData:auth,signature}).toString("base64url");
    expect(verifyAssertion(proof,publicKey,0,data,fixtureEnv)).toBe(1);
    expect(() => verifyAssertion(proof,publicKey,1,data,fixtureEnv)).toThrow();
    for (const changed of [data+"other",admissionData("https://other.test","challenge","key","phone"),admissionData("https://relay.test","other","key","phone"),admissionData("https://relay.test","challenge","key","other")]) {
      expect(() => verifyAssertion(proof,publicKey,0,changed,fixtureEnv)).toThrow();
    }
    expect(() => verifyAssertion(proof,publicKey,0,data,{...fixtureEnv,APP_ATTEST_APP_ID:"other.app"})).toThrow();
  });
  it("fails closed on Apple outages and never follows a provider redirect", async () => {
    vi.useFakeTimers(); vi.setSystemTime(new Date("2026-04-21T18:14:00Z"));
    const attestation=attestationDetails(encodedVector,keyId,Buffer.from(vector.challenge),fixtureEnv,false);
    const key=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
    const config={...fixtureEnv,APP_ATTEST_FRAUD_KEY_ID:'FIXTURE',APP_ATTEST_FRAUD_PRIVATE_KEY:key.privateKey.export({format:'pem',type:'pkcs8'}).toString()};
    const fetch=vi.spyOn(globalThis,'fetch');
    for(const status of [503,429,302]) {
      fetch.mockResolvedValueOnce(new Response(null,{status,headers:{Location:'https://other.test'}}));
      await expect(assessAttestation(attestation,config)).rejects.toThrow('app_verification_unavailable');
      const [url,options]=fetch.mock.calls.at(-1)!;
      expect(String(url)).toBe('https://data.appattest.apple.com/v1/attestationData');
      expect(options!.redirect).toBe('manual');
      expect(options!.body).toBe(attestation.receipt.toString('base64'));
    }
    expect(fetch).toHaveBeenCalledTimes(3);
  });
});
