import { DurableObject } from "cloudflare:workers";
import { exactKeys, HttpError, handleErrors, json } from "./http";
import { key32, type SetupTicket } from "./setup-ticket";
import { sameHash, UUID_PATTERN } from "./protocol";
import { pushEnvironmentAllowed, sendSetupPush, type PushEnvironment } from "./apns";

type Intent = SetupTicket & { owner_hash: string; status: "pending" | "complete" | "cancelled"; selected?: string;
  push_token?: string; push_env?: PushEnvironment; notified?: boolean };
type Claim = { claim_id: string; installation_id: string; host_public_key: string; host_name: string; commitment: string;
  token_hash: string; phone_ephemeral?: string; host_ephemeral?: string; confirmation?: string; envelope?: string; deadline?: number };

/** One temporary setup attempt is one coordination atom. Credentials remain ciphertext.
 * All transitions are synchronous SQLite transactions; public calls use authenticated RPCs. */
export class SetupIntent extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS claims (id TEXT PRIMARY KEY, value TEXT NOT NULL)");
    });
  }
  async dispatch(action: string, hash: string, body: Record<string, unknown>, id?: string): Promise<Response> {
    return handleErrors(async () => {
      if (action === "snapshot") return json(this.snapshot(hash, id));
      if (action === "claim") this.addClaim(body, hash);
      else if (action === "push") this.registerPush(hash, body);
      else if (action === "complete" || action === "cancel") { exactKeys(body, []); this.finish(hash, action === "cancel"); }
      else if (id) this.transition(hash, id, action, body);
      else throw new HttpError(404, "not_found");
      return json({ status: "ok" });
    });
  }
  private intent(): Intent {
    const row = this.ctx.storage.sql.exec<{ value: string }>("SELECT value FROM state WHERE id=1").toArray()[0];
    if (!row) throw new HttpError(404, "setup_not_found");
    const value: Intent = JSON.parse(row.value);
    if (value.expires_at * 1000 <= Date.now()) throw new HttpError(410, "setup_expired");
    return value;
  }
  private save(value: Intent): void {
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO state VALUES (1, ?)", JSON.stringify(value));
  }
  private claims(): Claim[] {
    return this.ctx.storage.sql.exec<{ value: string }>("SELECT value FROM claims ORDER BY id").toArray().map(x => JSON.parse(x.value));
  }
  private claim(id: string): Claim {
    const claim = this.claims().find(x => x.claim_id === id);
    if (!claim) throw new HttpError(404, "claim_not_found");
    return claim;
  }
  private saveClaim(claim: Claim): void {
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO claims VALUES (?, ?)", claim.claim_id, JSON.stringify(claim));
  }
  private owner(intent: Intent, hash: string): void {
    if (!sameHash(hash, intent.owner_hash)) throw new HttpError(401, "unauthorized");
  }
  private publicClaim(claim: Claim) {
    const { token_hash: _hash, ...publicValue } = claim;
    return publicValue;
  }
  async initialize(intent: SetupTicket, ownerHash: string): Promise<void> {
    if (this.ctx.storage.sql.exec("SELECT id FROM state").toArray().length) throw new HttpError(409, "setup_exists");
    this.save({ ...intent, owner_hash: ownerHash, status: "pending" });
    await this.ctx.storage.setAlarm(intent.expires_at * 1000);
  }
  snapshot(hash: string, id?: string) {
    const intent = this.intent();
    if (!id) {
      this.owner(intent, hash);
      return { status: intent.status, selected: intent.selected ?? null, expires_at: intent.expires_at,
        claims: this.claims().filter(x => !intent.selected || x.claim_id === intent.selected).map(x => this.publicClaim(x)) };
    }
    const claim = this.claim(id);
    if (!sameHash(hash, claim.token_hash)) throw new HttpError(401, "unauthorized");
    return { ...this.publicClaim(claim), status: intent.status !== "pending" ? intent.status
      : intent.selected && intent.selected !== id ? "cancelled" : "pending" };
  }
  addClaim(body: Record<string, unknown>, hash: string): void {
    exactKeys(body, ["claim_id", "installation_id", "host_public_key", "host_name", "commitment", "claim_token"]);
    const { claim_id, installation_id, host_public_key, host_name, commitment } = body;
    if (typeof claim_id !== "string" || !UUID_PATTERN.test(claim_id) || typeof installation_id !== "string" || !UUID_PATTERN.test(installation_id)
      || !key32(host_public_key) || !key32(commitment) || typeof host_name !== "string" || !/^[\x20-\x7E]{1,80}$/.test(host_name)) throw new HttpError(400, "invalid_claim");
    this.ctx.storage.transactionSync(() => {
      const intent = this.intent();
      const claims = this.claims();
      const existing = claims.find(x => x.claim_id === claim_id);
      if (existing) {
        if (existing.installation_id !== installation_id || existing.host_public_key !== host_public_key || existing.host_name !== host_name
          || existing.commitment !== commitment || !sameHash(hash, existing.token_hash)) throw new HttpError(409, "claim_changed");
        return;
      }
      if (intent.status !== "pending" || intent.selected) throw new HttpError(409, "setup_closed");
      if (claims.length >= 3) throw new HttpError(429, "too_many_claims");
      this.saveClaim({ claim_id, installation_id, host_public_key, host_name, commitment, token_hash: hash });
    });
    this.ctx.waitUntil(this.notify());
  }
  transition(hash: string, id: string, action: string, body: Record<string, unknown>): void {
    this.ctx.storage.transactionSync(() => {
      const intent = this.intent();
      const claim = this.claim(id);
      const isPhone = ["key", "confirm"].includes(action);
      if (isPhone) this.owner(intent, hash);
      else if (!sameHash(hash, claim.token_hash)) throw new HttpError(401, "unauthorized");
      if (intent.status !== "pending" || (intent.selected && intent.selected !== id)) throw new HttpError(409, "setup_closed");
      if (claim.deadline && claim.deadline * 1000 <= Date.now()) throw new HttpError(410, "claim_expired");
      const field = action === "key" ? "phone_ephemeral" : action === "reveal" ? "host_ephemeral" : action === "confirm" ? "confirmation" : action === "enrollment" ? "envelope" : undefined;
      if (!field) throw new HttpError(404, "not_found");
      exactKeys(body, [field]);
      const value = body[field];
      if (field === "envelope") {
        if (typeof value !== "string" || !/^[A-Za-z0-9_-]{64,4096}$/.test(value)) throw new HttpError(400, "invalid_envelope");
      } else if (!key32(value)) throw new HttpError(400, "invalid_key");
      if (typeof value !== "string") throw new HttpError(400, "invalid_value");
      if (claim[field] !== undefined && claim[field] !== value) throw new HttpError(409, "immutable_message");
      if ((action === "reveal" && !claim.phone_ephemeral) || (action === "confirm" && !claim.host_ephemeral)
        || (action === "enrollment" && (!claim.confirmation || intent.selected !== id))) throw new HttpError(409, "out_of_order");
      if (action === "key" && !claim.deadline) claim.deadline = Math.min(intent.expires_at, Math.floor(Date.now() / 1000) + 300);
      if (action === "confirm") { intent.selected = id; this.save(intent); }
      claim[field] = value;
      this.saveClaim(claim);
    });
  }
  finish(hash: string, cancelled: boolean): void {
    this.ctx.storage.transactionSync(() => {
      const intent = this.intent();
      this.owner(intent, hash);
      if (!cancelled && !intent.selected) throw new HttpError(409, "not_confirmed");
      if (intent.status !== "pending") return;
      intent.status = cancelled ? "cancelled" : "complete";
      delete intent.push_token; delete intent.push_env;
      this.save(intent);
      // Retain only claim routing/auth tombstones until expiry, so hosts can observe closure.
      for (const claim of this.claims()) {
        delete claim.envelope; delete claim.confirmation; delete claim.phone_ephemeral; delete claim.host_ephemeral;
        this.saveClaim(claim);
      }
    });
  }
  registerPush(hash: string, body: Record<string, unknown>): void {
    exactKeys(body, ["apns_token", "environment"]);
    const { apns_token, environment } = body;
    if (typeof apns_token !== "string" || !/^(?:[0-9a-fA-F]{2}){16,128}$/.test(apns_token)
      || (environment !== "sandbox" && environment !== "production") || !pushEnvironmentAllowed(this.env, environment)) throw new HttpError(400, "invalid_push");
    const intent = this.intent();
    this.owner(intent, hash);
    if (intent.status !== "pending") throw new HttpError(409, "setup_closed");
    intent.push_token = apns_token.toLowerCase(); intent.push_env = environment;
    this.save(intent);
    this.ctx.waitUntil(this.notify());
  }
  private async notify(): Promise<void> {
    let intent: Intent;
    try { intent = this.intent(); } catch { return; }
    if (intent.status !== "pending" || intent.notified || !intent.push_token || !intent.push_env || !this.claims().length) return;
    intent.notified = true; this.save(intent); // At most one doorbell, even concurrent claims/registers.
    if (!await this.env.ADMISSION.getByName("service").push()) return;
    await sendSetupPush(this.env, intent.push_token, intent.push_env, intent.intent_id, intent.expires_at);
  }
  alarm(): void {
    this.ctx.storage.transactionSync(() => {
      this.ctx.storage.sql.exec("DELETE FROM claims; DELETE FROM state");
    });
  }
}
