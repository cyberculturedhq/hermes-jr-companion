import { DurableObject } from "cloudflare:workers";
import { HttpError, rpcResult } from "./http";

// Guarantees fit the ceilings: 250*250 + 37,500 = 100,000 requests;
// 250*10 + 300 burst + 200 setup = 3,000 push attempts.
export const SERVICE_LIMITS = { registrationsPerDay: 25, installationsActive: 250, identitiesActive: 250,
  requestsPerDay: 100_000, requestsGuaranteed: 250, requestBurst: 37_500,
  pushesPerDay: 3_000, pushesGuaranteed: 10, pushBurst: 300, setupPushes: 200 };
type Entry = { id: string; identity: string; provisional_until: number };

export class ServiceAdmission extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS admitted (id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY, day INTEGER NOT NULL, used INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS totals (name TEXT PRIMARY KEY, used INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS creation_work (id TEXT PRIMARY KEY, created INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS setup_reservations (id TEXT PRIMARY KEY, identity TEXT NOT NULL, expires INTEGER NOT NULL, installation_id TEXT, host_hash TEXT);
        CREATE TABLE IF NOT EXISTS retired (id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS guarantees (identity TEXT PRIMARY KEY, day INTEGER NOT NULL);`);
      const columns = new Set(ctx.storage.sql.exec<{name: string}>("PRAGMA table_info(admitted)").toArray().map(x => x.name));
      if (!columns.has("identity")) ctx.storage.sql.exec("ALTER TABLE admitted ADD COLUMN identity TEXT NOT NULL DEFAULT ''");
      if (!columns.has("provisional_until")) ctx.storage.sql.exec("ALTER TABLE admitted ADD COLUMN provisional_until INTEGER NOT NULL DEFAULT 0");
      ctx.storage.sql.exec("UPDATE admitted SET identity='legacy:' || id WHERE identity=''");
    });
  }
  private used(name: string): number {
    return this.ctx.storage.sql.exec<{used: number}>("SELECT used FROM counters WHERE name=? AND day=?", name, Math.floor(Date.now()/86400_000)).toArray()[0]?.used ?? 0;
  }
  private increment(name: string): void {
    this.ctx.storage.sql.exec("INSERT INTO counters VALUES(?,?,1) ON CONFLICT(name) DO UPDATE SET day=excluded.day,used=CASE WHEN counters.day=excluded.day THEN counters.used+1 ELSE 1 END", name, Math.floor(Date.now()/86400_000));
  }
  private entry(id: string): Entry | undefined {
    return this.ctx.storage.sql.exec<Entry>("SELECT * FROM admitted WHERE id=? AND (provisional_until=0 OR provisional_until>?)", id, Date.now()).toArray()[0];
  }
  private creationAllowed(): boolean {
    this.ctx.storage.sql.exec("DELETE FROM creation_work WHERE created<=?", Date.now()-86400_000);
    return this.env.REGISTRATIONS_ENABLED === "true"
      && this.ctx.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM creation_work").one().count < SERVICE_LIMITS.registrationsPerDay
      && this.ctx.storage.sql.exec<{count: number}>("SELECT (SELECT COUNT(*) FROM admitted)+(SELECT COUNT(*) FROM retired) AS count").one().count < SERVICE_LIMITS.installationsActive;
  }
  private identities(): number {
    return this.ctx.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM (SELECT identity FROM admitted WHERE substr(identity,1,7)!='legacy:' UNION SELECT identity FROM setup_reservations WHERE expires>?)", Date.now()).one().count;
  }
  private guarantee(identity: string): boolean {
    const day=Math.floor(Date.now()/86400_000);
    if (this.ctx.storage.sql.exec('SELECT identity FROM guarantees WHERE identity=? AND day=?',identity,day).toArray().length) return true;
    if (this.ctx.storage.sql.exec<{count:number}>('SELECT COUNT(*) AS count FROM guarantees WHERE day=?',day).one().count>=SERVICE_LIMITS.identitiesActive) return false;
    this.ctx.storage.sql.exec('INSERT INTO guarantees VALUES(?,?) ON CONFLICT(identity) DO UPDATE SET day=excluded.day',identity,day);
    return true;
  }
  identityRegistered(identity: string): boolean {
    return this.ctx.storage.sql.exec("SELECT id FROM admitted WHERE identity=? UNION SELECT id FROM setup_reservations WHERE identity=? AND expires>?", identity, identity, Date.now()).toArray().length > 0;
  }
  async reserveSetup(id: string, identity: string, expires: number): Promise<boolean> {
    const prior=this.ctx.storage.sql.exec<{identity:string; expires:number}>("SELECT identity,expires FROM setup_reservations WHERE id=?",id).toArray()[0];
    if (prior) return prior.identity===identity && prior.expires===expires && prior.expires>Date.now();
    if (expires<=Date.now() || expires>Date.now()+1200_000) return false;
    if ((!this.identityRegistered(identity) && this.identities() >= SERVICE_LIMITS.identitiesActive) || !this.setup(true)) return false;
    this.ctx.storage.sql.exec("INSERT INTO setup_reservations(id,identity,expires) VALUES(?,?,?)", id, identity, expires);
    await this.ctx.storage.setAlarm(Date.now()+60_000);
    return true;
  }
  reserve(id: string): boolean {
    return this.ctx.storage.transactionSync(() => {
      if (!this.creationAllowed() || this.identities() >= SERVICE_LIMITS.identitiesActive) { this.increment("rejected"); return false; }
      this.ctx.storage.sql.exec("INSERT INTO admitted VALUES(?,?,0)", id, "legacy:"+id);
      this.created(id); return true;
    });
  }
  private created(id: string): void {
    this.ctx.storage.sql.exec("INSERT INTO creation_work VALUES(?,?)", id, Date.now());
    this.ctx.storage.sql.exec("INSERT INTO totals VALUES('created',1) ON CONFLICT(name) DO UPDATE SET used=used+1");
    this.increment("registrations");
  }
  async reserveTicket(intentId: string, hostHash: string) {
    return rpcResult(() => this.allocateTicket(intentId,hostHash));
  }
  private allocateTicket(intentId: string, hostHash: string): string {
    return this.ctx.storage.transactionSync(() => {
      const reservation = this.ctx.storage.sql.exec<{identity: string; expires: number; installation_id: string | null; host_hash: string | null}>("SELECT * FROM setup_reservations WHERE id=?", intentId).toArray()[0];
      if (!reservation || reservation.expires<=Date.now()) throw new HttpError(410,"reservation_expired");
      if (reservation.installation_id) {
        if (reservation.host_hash!==hostHash || !this.entry(reservation.installation_id)) throw new HttpError(409,"reservation_used");
        return reservation.installation_id;
      }
      if (!this.creationAllowed()) throw new HttpError(503,"registration_capacity_reached");
      const id=crypto.randomUUID();
      this.ctx.storage.sql.exec("INSERT INTO admitted VALUES(?,?,?)",id,reservation.identity,reservation.expires);
      this.ctx.storage.sql.exec("UPDATE setup_reservations SET installation_id=?,host_hash=? WHERE id=?",id,hostHash,intentId);
      this.created(id); return id;
    });
  }
  async promote(id: string, intentId: string) {
    return rpcResult(() => this.promoteTicket(id,intentId));
  }
  private promoteTicket(id: string, intentId: string): void {
    this.ctx.storage.transactionSync(() => {
      const reservation=this.ctx.storage.sql.exec<{identity: string; expires: number}>("SELECT identity,expires FROM setup_reservations WHERE id=?",intentId).toArray()[0];
      const prior=this.entry(id);
      if (!reservation || reservation.expires<=Date.now() || !prior) throw new HttpError(410,"reservation_expired");
      if (prior.identity.startsWith('legacy:') && prior.identity!==reservation.identity) {
        const day=Math.floor(Date.now()/86400_000);
        const granted=this.ctx.storage.sql.exec('SELECT identity FROM guarantees WHERE identity=? AND day=?',prior.identity,day).toArray().length;
        const target=this.ctx.storage.sql.exec('SELECT identity FROM guarantees WHERE identity=? AND day=?',reservation.identity,day).toArray().length;
        if (granted && !target) {
          this.ctx.storage.sql.exec('INSERT INTO guarantees VALUES(?,?) ON CONFLICT(identity) DO UPDATE SET day=excluded.day',reservation.identity,day);
          this.ctx.storage.sql.exec('DELETE FROM guarantees WHERE identity=?',prior.identity);
        }
        // Keep spent shares when identities merge. Verification must not reset a daily allowance.
        for (const kind of ['requests:','pushes:']) {
          const used=this.used(kind+prior.identity)+this.used(kind+reservation.identity);
          this.ctx.storage.sql.exec('INSERT INTO counters VALUES(?,?,?) ON CONFLICT(name) DO UPDATE SET day=excluded.day,used=excluded.used',kind+reservation.identity,day,used);
        }
      }
      // The first verified phone anchors capacity. A later pairing cannot rotate that allowance.
      this.ctx.storage.sql.exec("UPDATE admitted SET identity=CASE WHEN provisional_until>0 OR substr(identity,1,7)='legacy:' THEN ? ELSE identity END,provisional_until=0 WHERE id=?",reservation.identity,id);
    });
  }
  registered(id: string): boolean { return Boolean(this.entry(id)); }
  admit(id: string): boolean { return this.admissionResult(id)==="admitted"; }
  admissionResult(id: string): "admitted" | "unknown" | "capacity" {
    return this.ctx.storage.transactionSync(() => {
      const entry=this.entry(id);
      if (!entry) return "unknown";
      const owner="requests:"+entry.identity, burst=!this.guarantee(entry.identity) || this.used(owner)>=SERVICE_LIMITS.requestsGuaranteed;
      if (this.used("requests")>=SERVICE_LIMITS.requestsPerDay || (burst && this.used("request_burst")>=SERVICE_LIMITS.requestBurst)) {
        this.increment("rejected"); return "capacity";
      }
      this.increment(owner); this.increment("requests");
      if (burst) this.increment("request_burst");
      return "admitted";
    });
  }
  async remove(id: string): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM admitted WHERE id=?",id);
    this.ctx.storage.sql.exec("INSERT OR IGNORE INTO retired VALUES(?)",id);
    await this.ctx.storage.setAlarm(Date.now()+1000);
  }
  setup(create: boolean): boolean {
    return this.ctx.storage.transactionSync(() => {
      if ((create && this.env.REGISTRATIONS_ENABLED!=="true") || (create && this.used("setups")>=100)) { this.increment("rejected"); return false; }
      if (create) this.increment("setups");
      return true;
    });
  }
  push(id?: string): boolean {
    return this.ctx.storage.transactionSync(() => {
      const entry=id ? this.entry(id) : undefined;
      if (!entry || this.env.RELAY_ENABLED!=="true") return false;
      const owner="pushes:"+entry.identity, burst=!this.guarantee(entry.identity) || this.used(owner)>=SERVICE_LIMITS.pushesGuaranteed;
      if (this.used("pushes")>=SERVICE_LIMITS.pushesPerDay || (burst && this.used("push_burst")>=SERVICE_LIMITS.pushBurst)) { this.increment("rejected"); return false; }
      this.increment(owner); this.increment("pushes");
      if (burst) this.increment("push_burst");
      return true;
    });
  }
  setupPush(): boolean {
    return this.ctx.storage.transactionSync(() => {
      if (this.env.RELAY_ENABLED!=="true" || this.used("setup_pushes")>=SERVICE_LIMITS.setupPushes || this.used("pushes")>=SERVICE_LIMITS.pushesPerDay) return false;
      this.increment("setup_pushes"); this.increment("pushes"); return true;
    });
  }
  async alarm(): Promise<void> {
    await this.ctx.storage.setAlarm(Date.now()+60_000);
    const expired=this.ctx.storage.sql.exec<{id: string}>("SELECT id FROM admitted WHERE provisional_until>0 AND provisional_until<=?",Date.now()).toArray();
    for (const entry of expired) await this.remove(entry.id);
    for (const entry of this.ctx.storage.sql.exec<{id: string}>("SELECT id FROM retired").toArray()) {
      await this.env.INSTALLATIONS.getByName(entry.id).destroy();
      this.ctx.storage.sql.exec("DELETE FROM retired WHERE id=?",entry.id);
    }
    this.ctx.storage.sql.exec("DELETE FROM setup_reservations WHERE expires<=?",Date.now());
    this.ctx.storage.sql.exec("DELETE FROM counters WHERE day<?",Math.floor(Date.now()/86400_000)-1);
    this.ctx.storage.sql.exec("DELETE FROM creation_work WHERE created<=?",Date.now()-86400_000);
    this.ctx.storage.sql.exec('DELETE FROM guarantees WHERE day<?',Math.floor(Date.now()/86400_000));
    if (!this.ctx.storage.sql.exec<{count: number}>("SELECT (SELECT COUNT(*) FROM setup_reservations)+(SELECT COUNT(*) FROM retired) AS count").one().count) await this.ctx.storage.deleteAlarm();
  }
  status() {
    return { day:new Date().toISOString().slice(0,10),limits:SERVICE_LIMITS,
      registrations_enabled:this.env.REGISTRATIONS_ENABLED==="true",relay_enabled:this.env.RELAY_ENABLED==="true",
      installations:this.ctx.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM admitted").one().count,
      lifetime_created:this.ctx.storage.sql.exec<{used: number}>("SELECT used FROM totals WHERE name='created'").toArray()[0]?.used ?? 0,
      today:Object.fromEntries(["registrations","requests","pushes","rejected","setups","setup_pushes","push_burst"].map(name=>[name,this.used(name)])) };
  }
}
