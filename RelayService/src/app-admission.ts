import { DurableObject } from "cloudflare:workers";
import { createHash } from "node:crypto";
import { admissionData, verifyAssertion, verifyAttestation } from "./app-attest";
import { assessAttestation } from "./app-receipt";
import { makeChallenge, challengeExpiry } from "./app-challenge";
import { HttpError, rpcResult } from "./http";
import { newToken } from "./protocol";

type Challenge = { id: string; key_id: string; phone_key: string; origin: string; expires: number;
  proof_hash: string | null; intent_id: string | null; owner_token: string | null; issued: number | null };
type AppKey = { public_key: string; counter: number };

/** Bounded official-app verification state. No message contents or Apple private keys. */
export class AppAdmission extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS app_keys (
        id TEXT PRIMARY KEY, public_key TEXT NOT NULL, counter INTEGER NOT NULL, touched INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS challenges (id TEXT PRIMARY KEY, key_id TEXT NOT NULL, phone_key TEXT NOT NULL,
        origin TEXT NOT NULL, expires INTEGER NOT NULL, proof_hash TEXT, intent_id TEXT, owner_token TEXT, issued INTEGER);`);
    });
  }
  async challenge(keyId: string, phoneKey: string, origin: string) {
    return rpcResult(() => this.createChallenge(keyId,phoneKey,origin));
  }
  private async createChallenge(keyId: string, phoneKey: string, origin: string) {
    const attested = this.ctx.storage.sql.exec("SELECT id FROM app_keys WHERE id=?",keyId).toArray().length>0;
    return {challenge: makeChallenge(this.env,keyId,phoneKey,origin), attested};
  }
  private readChallenge(keyId: string, phoneKey: string, origin: string, id: string): Challenge {
    const expires=challengeExpiry(this.env,id,keyId,phoneKey,origin);
    const prior=this.ctx.storage.sql.exec<Challenge>("SELECT * FROM challenges WHERE id=?",id).toArray()[0];
    if (prior) {
      if (prior.key_id!==keyId || prior.phone_key!==phoneKey || prior.origin!==origin) throw new HttpError(403,"invalid_challenge");
      return prior;
    }
    return {id,key_id:keyId,phone_key:phoneKey,origin,expires,proof_hash:null,intent_id:null,owner_token:null,issued:null};
  }
  private pending = new Map<string, Promise<unknown>>();
  async verify(keyId: string, phoneKey: string, origin: string, challengeId: string, proof: string, assertion: boolean) {
    return rpcResult(() => this.verifyProof(keyId,phoneKey,origin,challengeId,proof,assertion));
  }
  private async verifyProof(keyId: string, phoneKey: string, origin: string, challengeId: string, proof: string, assertion: boolean) {
    // Apple calls stay outside SQL transactions. Coalesce exact retries while the request runs.
    const workKey = createHash("sha256").update(JSON.stringify([keyId,phoneKey,origin,challengeId,proof,assertion])).digest("hex");
    const active = this.pending.get(workKey);
    if (active) return active as Promise<{identity: string; intent_id: string; owner_token: string; issued: number}>;
    if (this.pending.size >= 8) throw new HttpError(429, "verification_busy");
    const work = async () => {
      let checked: string | undefined;
      if (!assertion) {
        const pending = this.readChallenge(keyId,phoneKey,origin,challengeId);
        if (!pending || pending.key_id !== keyId || pending.phone_key !== phoneKey || pending.origin !== origin || pending.expires <= Date.now()) throw new HttpError(403, "invalid_challenge");
        if (!pending.proof_hash) {
          if (this.ctx.storage.sql.exec("SELECT id FROM app_keys WHERE id=?", keyId).toArray().length) throw new HttpError(409,"assertion_required");
          if (this.ctx.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM app_keys").one().count >= 250) throw new HttpError(429,"verification_capacity_reached");
          const attestation = verifyAttestation(proof, keyId, admissionData(origin, challengeId, keyId, phoneKey), this.env);
          await assessAttestation(attestation, this.env);
          checked = attestation.publicKey;
        }
      }
      return this.ctx.storage.transactionSync(() => {
      const challenge = this.readChallenge(keyId,phoneKey,origin,challengeId);
      if (!challenge || challenge.key_id !== keyId || challenge.phone_key !== phoneKey || challenge.origin !== origin || challenge.expires <= Date.now()) throw new HttpError(403, "invalid_challenge");
      const proofHash = createHash("sha256").update(`${assertion}\n${proof}`).digest("hex");
      // Exact retries return one attempt. Changed requests cannot reuse consumed authority.
      if (challenge.proof_hash) {
        if (proofHash !== challenge.proof_hash) throw new HttpError(409, "challenge_used");
        return { identity: keyId, intent_id: challenge.intent_id!, owner_token: challenge.owner_token!, issued: challenge.issued! };
      }
      this.ctx.storage.sql.exec("DELETE FROM challenges WHERE expires<=?",Date.now());
      if (this.ctx.storage.sql.exec<{count:number}>("SELECT COUNT(*) AS count FROM challenges WHERE key_id=?",keyId).one().count>=3) throw new HttpError(429,"verification_capacity_reached");
      const key = this.ctx.storage.sql.exec<AppKey>("SELECT public_key,counter FROM app_keys WHERE id=?", keyId).toArray()[0];
      const clientData = admissionData(origin, challengeId, keyId, phoneKey);
      let publicKey: string, counter: number;
      if (assertion) {
        if (!key) throw new HttpError(403, "attestation_required");
        publicKey = key.public_key;
        counter = verifyAssertion(proof, publicKey, key.counter, clientData, this.env);
      } else {
        if (key) throw new HttpError(409, "assertion_required");
        if (this.ctx.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM app_keys").one().count >= 250) throw new HttpError(429, "verification_capacity_reached");
        if (!checked) throw new HttpError(403,"app_verification_failed");
        publicKey = checked; counter = 0;
      }
      this.ctx.storage.sql.exec("INSERT INTO app_keys VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET counter=excluded.counter,touched=excluded.touched", keyId, publicKey, counter, Date.now());
      const intentId = newToken(), ownerToken = newToken(), issued = Math.floor(Date.now() / 1000);
      this.ctx.storage.sql.exec("INSERT INTO challenges VALUES(?,?,?,?,?,?,?,?,?)",challengeId,keyId,phoneKey,origin,challenge.expires,proofHash,intentId,ownerToken,issued);
      return { identity: keyId, intent_id: intentId, owner_token: ownerToken, issued };
      });
    };
    const promise = work();
    this.pending.set(workKey, promise);
    try { const result=await promise; await this.ctx.storage.setAlarm(Date.now()+1200_000); return result; } finally { this.pending.delete(workKey); }
  }
  async alarm(): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM challenges WHERE expires <= ?", Date.now());
    const keys = this.ctx.storage.sql.exec<{id: string}>("SELECT id FROM app_keys WHERE touched < ?", Date.now() - 86400_000).toArray();
    for (const key of keys) {
      if (!await this.env.ADMISSION.getByName("service").identityRegistered(key.id)) this.ctx.storage.sql.exec("DELETE FROM app_keys WHERE id=? AND touched < ?", key.id, Date.now() - 86400_000);
    }
    // Periodic cleanup also covers a lost response after successful verification.
    if (this.ctx.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM app_keys").one().count) await this.ctx.storage.setAlarm(Date.now() + 86400_000);
  }
}
