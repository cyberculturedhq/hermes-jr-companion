import { Buffer } from "node:buffer";
import { createHmac, timingSafeEqual } from "node:crypto";
import { HttpError } from "./http";

function mac(env: Env, data: string | Buffer): Buffer {
  if (!env.SETUP_TICKET_PRIVATE_KEY) throw new HttpError(503,"app_verification_unavailable");
  return createHmac('sha256',env.SETUP_TICKET_PRIVATE_KEY).update(data).digest();
}
function tag(env: Env, nonce: Buffer, key: string, phone: string, origin: string): Buffer {
  return mac(env,`hermes-jr/challenge/v1\n${nonce.toString('base64url')}\n${key}\n${phone}\n${origin}\n`).subarray(0,16);
}
// Public challenge requests allocate no storage and consume no protected allowance.
export function makeChallenge(env: Env, key: string, phone: string, origin: string): string {
  const issued=Math.floor(Date.now()/300_000)*300;
  const nonce=Buffer.alloc(16); nonce.writeUInt32BE(issued);
  mac(env,`hermes-jr/challenge-seed/v1\n${issued}\n${key}\n${phone}\n${origin}\n`).copy(nonce,4,0,12);
  return Buffer.concat([nonce,tag(env,nonce,key,phone,origin)]).toString('base64url');
}
export function challengeExpiry(env: Env, challenge: string, key: string, phone: string, origin: string): number {
  const bytes=Buffer.from(challenge,'base64url');
  if (bytes.length!==32 || bytes.toString('base64url')!==challenge) throw new HttpError(403,'invalid_challenge');
  const issued=bytes.readUInt32BE(), now=Math.floor(Date.now()/1000);
  if (issued>now || issued+1200<=now || !timingSafeEqual(bytes.subarray(16),tag(env,bytes.subarray(0,16),key,phone,origin))) throw new HttpError(403,'invalid_challenge');
  return (issued+1200)*1000;
}
