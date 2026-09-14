import { DurableObject } from "cloudflare:workers";

// The coordination atom is the service admission budget. Encrypted WebSocket frames
// stay on their installation objects and never pass through this directory.
export const SERVICE_LIMITS = { registrationsPerDay: 25, installationsLifetime: 250, requestsPerDay: 100_000, pushesPerDay: 3_000 };
type Counter = "registrations" | "requests" | "pushes" | "rejected" | "setups";
export class ServiceAdmission extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS admitted (id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY, day INTEGER NOT NULL, used INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS totals (name TEXT PRIMARY KEY, used INTEGER NOT NULL);`);
    });
  }
  private used(name: Counter): number {
    return this.ctx.storage.sql.exec<{used: number}>("SELECT used FROM counters WHERE name = ? AND day = ?", name, Math.floor(Date.now() / 86400_000)).toArray()[0]?.used ?? 0;
  }
  private increment(name: Counter): void {
    this.ctx.storage.sql.exec("INSERT INTO counters VALUES (?, ?, 1) ON CONFLICT(name) DO UPDATE SET day = excluded.day, used = CASE WHEN counters.day = excluded.day THEN counters.used + 1 ELSE 1 END", name, Math.floor(Date.now() / 86400_000));
  }
  reserve(id: string): boolean {
    return this.ctx.storage.transactionSync(() => {
      const total = this.ctx.storage.sql.exec<{used: number}>("SELECT used FROM totals WHERE name = 'created'").toArray()[0]?.used ?? 0;
      if (this.env.REGISTRATIONS_ENABLED !== "true" || total >= SERVICE_LIMITS.installationsLifetime || this.used("registrations") >= SERVICE_LIMITS.registrationsPerDay) {
        this.increment("rejected"); return false;
      }
      this.ctx.storage.sql.exec("INSERT INTO admitted VALUES (?)", id);
      this.ctx.storage.sql.exec("INSERT INTO totals VALUES ('created', 1) ON CONFLICT(name) DO UPDATE SET used = used + 1");
      this.increment("registrations");
      return true;
    });
  }
  admit(id: string): boolean {
    return this.ctx.storage.transactionSync(() => {
      if (this.used("requests") >= SERVICE_LIMITS.requestsPerDay || !this.ctx.storage.sql.exec("SELECT id FROM admitted WHERE id = ?", id).toArray().length) {
        this.increment("rejected"); return false;
      }
      this.increment("requests"); return true;
    });
  }
  remove(id: string): void {
    // Never refund the lifetime budget: repeated create/delete must not allocate unlimited DOs.
    this.ctx.storage.sql.exec("DELETE FROM admitted WHERE id = ?", id);
  }
  setup(create: boolean): boolean {
    return this.ctx.storage.transactionSync(() => {
      if ((create && this.env.REGISTRATIONS_ENABLED !== "true") || this.used("requests") >= SERVICE_LIMITS.requestsPerDay
        || (create && this.used("setups") >= 100)) { this.increment("rejected"); return false; }
      this.increment("requests");
      if (create) this.increment("setups");
      return true;
    });
  }
  push(): boolean {
    return this.ctx.storage.transactionSync(() => {
      if (this.env.RELAY_ENABLED !== "true" || this.used("pushes") >= SERVICE_LIMITS.pushesPerDay) { this.increment("rejected"); return false; }
      this.increment("pushes"); return true;
    });
  }
  status() {
    return { day: new Date().toISOString().slice(0, 10), limits: SERVICE_LIMITS,
      registrations_enabled: this.env.REGISTRATIONS_ENABLED === "true", relay_enabled: this.env.RELAY_ENABLED === "true",
      installations: this.ctx.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM admitted").one().count,
      lifetime_created: this.ctx.storage.sql.exec<{used: number}>("SELECT used FROM totals WHERE name = 'created'").toArray()[0]?.used ?? 0,
      today: Object.fromEntries((["registrations", "requests", "pushes", "rejected"] as Counter[]).map(name => [name, this.used(name)])) };
  }
}
