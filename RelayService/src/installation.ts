import { DurableObject } from "cloudflare:workers";
import { pushAvailable, pushEnvironmentAllowed, sendPush, type EncryptedNotification, type PushEnvironment, type PushResult } from "./apns";
import { exactKeys, failure, handleErrors, HttpError, json, readJson } from "./http";
import { bearer, bytesUuid, LIMITS, newToken, REFERENCE_PATTERN, routedRecord, sameHash, tokenHash, UUID_PATTERN } from "./protocol";
import { key32 } from "./setup-ticket";

type Installation = { id: string; host_hash: string };
type Device = { id: string; token_hash: string; push_token: string | null; push_env: PushEnvironment | null; created_at: number };
type SocketState = { role: "host" | "device"; deviceId?: string; hostId: string; active: boolean };
type Budget = { key: string; period: number; maximum: number; amount?: number };
type PushReceipt = Omit<PushResult, "status"> & { status: PushResult["status"] | "pending"; expires_at: number };

/** One installation is one coordination atom. No application payload is ever stored. */
export class InstallationRelay extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS installation (id TEXT PRIMARY KEY, host_hash TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS devices (
          id TEXT PRIMARY KEY, token_hash TEXT NOT NULL, push_token TEXT, push_env TEXT, created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS budgets (key TEXT PRIMARY KEY, window INTEGER NOT NULL, used INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS push_receipts (
          device_id TEXT NOT NULL, reference TEXT NOT NULL, status TEXT NOT NULL, expires_at INTEGER NOT NULL,
          PRIMARY KEY (device_id, reference)
        );
      `);
      // Existing installations may contain receipts created before diagnostics existed.
      // Add nullable columns atomically and preserve those historical status values.
      ctx.storage.transactionSync(() => {
        const columns = new Set(ctx.storage.sql.exec<{ name: string }>("PRAGMA table_info(push_receipts)").toArray().map((column) => column.name));
        if (!columns.has("stage")) ctx.storage.sql.exec("ALTER TABLE push_receipts ADD COLUMN stage TEXT");
        if (!columns.has("apns_status")) ctx.storage.sql.exec("ALTER TABLE push_receipts ADD COLUMN apns_status INTEGER");
        if (!columns.has("reason")) ctx.storage.sql.exec("ALTER TABLE push_receipts ADD COLUMN reason TEXT");
      });
    });
  }

  /** Internal binding RPC only; the public Worker never maps an HTTP route to this method. */
  initialize(id: string, hostHash: string): void {
    if (!UUID_PATTERN.test(id) || !/^[A-Za-z0-9_-]{43}$/.test(hostHash)) throw new Error("Invalid registration");
    if (this.installation()) throw new Error("Installation exists");
    this.ctx.storage.sql.exec("INSERT INTO installation (id, host_hash) VALUES (?, ?)", id, hostHash);
  }

  authorizeSetup(hostHash: string): boolean {
    const current = this.installation();
    return current !== undefined && sameHash(hostHash, current.host_hash);
  }

  async fetch(request: Request): Promise<Response> {
    return handleErrors(async () => {
      const url = new URL(request.url);
      const match = /^\/v1\/installations\/([^/]+)(.*)$/.exec(url.pathname);
      const installation = this.installation();
      if (!match || !installation || match[1] !== installation.id) return failure(404, "not_found");
      const suffix = match[2];
      const deviceMatch = /^\/devices\/([^/]+)(\/connect|\/push(?:\/receipts\/([^/]+))?)?$/.exec(suffix);
      const deviceId = deviceMatch?.[1];
      const receiptReference = deviceMatch?.[3];
      if (deviceId && !UUID_PATTERN.test(deviceId)) return failure(404, "not_found");
      if (receiptReference && !REFERENCE_PATTERN.test(receiptReference)) return failure(404, "not_found");
      // Bound parsing before the final authorization check; no await between auth and mutation.
      const body = ["POST", "PUT"].includes(request.method) ? await readJson(request) : undefined;
      const rawToken = bearer(request);
      if (!rawToken) return failure(401, "unauthorized");
      const hash = await tokenHash(rawToken);
      const current = this.installation();
      if (!current) return failure(401, "unauthorized");
      const isHost = sameHash(hash, current.host_hash);
      const device = deviceId ? this.device(deviceId) : undefined;
      const isDevice = device !== undefined && sameHash(hash, device.token_hash);
      if (!isHost && !isDevice) return failure(401, "unauthorized");

      if (suffix === "/host" && request.method === "GET") {
        if (!isHost) return failure(403, "host_required");
        return this.upgrade(request, { role: "host", active: true });
      }
      if (deviceMatch?.[2] === "/connect" && request.method === "GET") {
        if (!isDevice) return failure(403, "device_required");
        return this.upgrade(request, { role: "device", deviceId, active: true });
      }

      this.spend([{ key: "management", period: 60, maximum: LIMITS.managementPerMinute }]);
      if (receiptReference && request.method === "GET") {
        if (!isHost) return failure(403, "host_required");
        if (!device) return failure(404, "not_found");
        const receipt = this.ctx.storage.sql.exec<PushReceipt>(
          "SELECT status, stage, apns_status, reason, expires_at FROM push_receipts WHERE device_id = ? AND reference = ? AND expires_at > ?",
          device.id, receiptReference, Date.now(),
        ).toArray()[0];
        return receipt ? json(receipt) : failure(404, "not_found");
      }
      if (suffix === "/devices" && request.method === "POST") {
        if (!isHost) return failure(403, "host_required");
        exactKeys(body!, []);
        return this.addDevice();
      }
      if (suffix === "/devices" && request.method === "GET") {
        if (!isHost) return failure(403, "host_required");
        return json({ devices: this.ctx.storage.sql.exec<Device>("SELECT * FROM devices ORDER BY created_at").toArray().map((entry) => ({
          device_id: entry.id, push_registered: Boolean(entry.push_token), connected: Boolean(this.deviceSocket(entry.id)),
        })) });
      }
      if (deviceMatch && !deviceMatch[2] && request.method === "PUT") {
        if (!isHost) return failure(403, "host_required");
        exactKeys(body!, ["device_token"]);
        if (!key32(body!.device_token)) return failure(400, "invalid_token");
        const desiredHash = await tokenHash(body!.device_token);
        // Recheck authority after hashing. Retries never rotate an existing credential.
        if (!this.authorizeSetup(hash)) return failure(401, "unauthorized");
        const existing = this.device(deviceId!);
        if (existing && !sameHash(existing.token_hash, desiredHash)) return failure(409, "device_exists");
        if (!existing) {
          if (this.ctx.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM devices").one().count >= LIMITS.devices) return failure(409, "device_limit");
          this.ctx.storage.sql.exec("INSERT INTO devices (id, token_hash, created_at) VALUES (?, ?, ?)", deviceId!, desiredHash, Date.now());
        }
        return json({ status: "ok" });
      }
      if (deviceMatch && !deviceMatch[2] && request.method === "DELETE") {
        if (!isHost) return failure(403, "host_required");
        this.removeDevice(deviceId!);
        return json({ status: "revoked" });
      }
      if (deviceMatch?.[2] === "/push") {
        if (request.method === "PUT") {
          if (!isDevice) return failure(403, "device_required");
          exactKeys(body!, ["apns_token", "environment"]);
          const { apns_token: token, environment } = body!;
          if (typeof token !== "string" || !/^(?:[0-9a-fA-F]{2}){16,128}$/.test(token)
            || (environment !== "sandbox" && environment !== "production")) throw new HttpError(400, "invalid_push_registration");
          if (!pushAvailable(this.env)) return failure(503, "push_unavailable");
          if (!pushEnvironmentAllowed(this.env, environment)) return failure(409, "push_environment_not_allowed");
          this.ctx.storage.sql.exec("UPDATE devices SET push_token = ?, push_env = ? WHERE id = ?", token.toLowerCase(), environment, deviceId!);
          return json({ status: "registered" });
        }
        if (request.method === "DELETE") {
          if (!isDevice && !isHost) return failure(403, "device_required");
          this.ctx.storage.sql.exec("UPDATE devices SET push_token = NULL, push_env = NULL WHERE id = ?", deviceId!);
          return json({ status: "unregistered" });
        }
        if (request.method === "POST") {
          if (!isHost) return failure(403, "host_required");
          exactKeys(body!, "encrypted" in body! ? ["reference", "encrypted"] : ["reference"]);
          let encrypted: EncryptedNotification | undefined;
          if ("encrypted" in body!) {
            const value = body!.encrypted;
            if (!value || typeof value !== "object" || Array.isArray(value)) throw new HttpError(400, "invalid_ciphertext");
            const fields = value as Record<string, unknown>;
            exactKeys(fields, ["v", "kid", "data"]);
            if (fields.v !== 1 || typeof fields.kid !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(fields.kid)
                || typeof fields.data !== "string" || !/^[A-Za-z0-9_-]{1403}$/.test(fields.data)) throw new HttpError(400, "invalid_ciphertext");
            encrypted = { v: 1, kid: fields.kid, data: fields.data };
          }
          if (typeof body!.reference !== "string" || !REFERENCE_PATTERN.test(body!.reference)) throw new HttpError(400, "invalid_reference");
          return this.push(device, body!.reference, encrypted);
        }
      }
      if (suffix === "" && request.method === "DELETE") {
        if (!isHost) return failure(403, "host_required");
        // Retain only the empty SQL schema. A random installation ID is never reused.
        this.ctx.storage.sql.exec("DELETE FROM installation; DELETE FROM devices; DELETE FROM budgets; DELETE FROM push_receipts;");
        for (const socket of this.sockets()) this.close(socket, 4003, "Installation removed");
        await this.env.ADMISSION.getByName("service").remove(installation.id);
        return json({ status: "deleted" });
      }
      return failure(404, "not_found");
    });
  }

  private installation(): Installation | undefined {
    return this.ctx.storage.sql.exec<Installation>("SELECT id, host_hash FROM installation LIMIT 1").toArray()[0];
  }

  private device(id: string): Device | undefined {
    return this.ctx.storage.sql.exec<Device>("SELECT * FROM devices WHERE id = ?", id).toArray()[0];
  }

  private async addDevice(): Promise<Response> {
    const token = newToken();
    const hash = await tokenHash(token);
    // Count after the await, so simultaneous provisioning cannot exceed the installation cap.
    if (!this.installation()) return failure(401, "unauthorized");
    const count = this.ctx.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM devices").one().count;
    if (count >= LIMITS.devices) return failure(409, "device_limit");
    const id = crypto.randomUUID();
    this.ctx.storage.sql.exec("INSERT INTO devices (id, token_hash, created_at) VALUES (?, ?, ?)", id, hash, Date.now());
    return json({ device_id: id, device_token: token }, 201);
  }

  private removeDevice(id: string): void {
    this.ctx.storage.sql.exec("DELETE FROM devices WHERE id = ?", id);
    this.ctx.storage.sql.exec("DELETE FROM push_receipts WHERE device_id = ?", id);
    this.ctx.storage.sql.exec("DELETE FROM budgets WHERE key IN (?, ?, ?)", `device_frames:${id}`, `device_bytes:${id}`, `device_pushes:${id}`);
    const socket = this.deviceSocket(id);
    if (socket) {
      this.close(socket, 4003, "Device revoked");
      this.notifyHost("peer_disconnected", id);
    }
  }

  /** Synchronous SQLite critical section: budgets survive hibernation and reconnects. */
  private spend(entries: Budget[]): void {
    const now = Math.floor(Date.now() / 1000);
    const planned = entries.map((entry) => {
      const window = Math.floor(now / entry.period);
      const previous = this.ctx.storage.sql.exec<{ window: number; used: number }>("SELECT window, used FROM budgets WHERE key = ?", entry.key).toArray()[0];
      const used = (previous?.window === window ? previous.used : 0) + (entry.amount ?? 1);
      if (used > entry.maximum) throw new HttpError(429, "rate_limited");
      return { key: entry.key, window, used };
    });
    this.ctx.storage.transactionSync(() => {
      for (const entry of planned) this.ctx.storage.sql.exec(
        "INSERT INTO budgets (key, window, used) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET window = excluded.window, used = excluded.used",
        entry.key, entry.window, entry.used,
      );
    });
  }

  private sockets(): WebSocket[] {
    return this.ctx.getWebSockets().filter((socket) => socket.readyState === WebSocket.OPEN && this.state(socket)?.active);
  }

  private state(socket?: WebSocket): SocketState | null { return socket?.deserializeAttachment() as SocketState | null ?? null; }
  private hostSocket(): WebSocket | undefined { return this.sockets().find((socket) => this.state(socket)?.role === "host"); }
  private deviceSocket(id: string): WebSocket | undefined { return this.sockets().find((socket) => this.state(socket)?.deviceId === id); }

  private upgrade(request: Request, input: Omit<SocketState, "hostId">): Response {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return failure(426, "websocket_required");
    this.spend([{ key: "connections", period: 60, maximum: LIMITS.connectionsPerMinute }]);
    const host = this.hostSocket();
    if (input.role === "host" && host) return failure(409, "host_already_connected");
    if (input.role === "device") {
      if (!host) return failure(409, "host_offline");
      if (this.deviceSocket(input.deviceId!)) return failure(409, "device_already_connected");
    } else {
      // A close callback can arrive after a replacement upgrade. Discard orphaned sockets
      // before accepting a new host; they must never become peers of its new connection.
      for (const orphan of this.sockets()) this.close(orphan, 4001, "Host disconnected");
    }
    if (this.sockets().length >= LIMITS.devices + 1) return failure(429, "connection_limit");
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    const state: SocketState = { ...input, hostId: input.role === "host" ? crypto.randomUUID() : this.state(host!)!.hostId };
    server.serializeAttachment(state);
    this.ctx.acceptWebSocket(server);
    if (state.role === "device") this.notifyHost("peer_connected", state.deviceId!);
    return new Response(null, { status: 101, webSocket: client });
  }

  private close(socket: WebSocket, code: number, reason: string): void {
    const state = this.state(socket);
    if (state) socket.serializeAttachment({ ...state, active: false });
    try { socket.close(code, reason); } catch { /* already disconnected */ }
  }

  private notifyHost(type: "peer_connected" | "peer_disconnected", deviceId: string): void {
    const host = this.hostSocket();
    if (host) {
      try { host.send(JSON.stringify({ type, device_id: deviceId })); }
      catch { this.disconnectHost(host); }
    }
  }

  private disconnectHost(host: WebSocket): void {
    const hostId = this.state(host)?.hostId;
    this.close(host, 4001, "Host disconnected");
    for (const device of this.sockets()) if (this.state(device)?.hostId === hostId) this.close(device, 4001, "Host disconnected");
  }

  webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): void {
    if (this.env.RELAY_ENABLED !== "true") { this.close(socket, 1013, "Service paused"); return; }
    const state = this.state(socket);
    if (!state?.active) return;
    if (typeof message === "string") { this.rejectSocket(socket, state, 1003, "Binary records required"); return; }
    const headerBytes = state.role === "host" ? LIMITS.routingHeaderBytes : 0;
    if (message.byteLength <= headerBytes || message.byteLength > LIMITS.ciphertextBytes + headerBytes) {
      this.rejectSocket(socket, state, 1009, "Record size limit"); return;
    }
    const id = state.role === "host" ? bytesUuid(new Uint8Array(message, 0, LIMITS.routingHeaderBytes)) : state.deviceId!;
    // Current durable admission, not just an attachment: revocation wins even during close races.
    if (!this.installation() || !UUID_PATTERN.test(id) || !this.device(id)) {
      this.rejectSocket(socket, state, 4003, "Unknown device"); return;
    }
    try {
      const bytes = message.byteLength - headerBytes;
      this.spend([
        { key: "frames", period: 60, maximum: LIMITS.framesPerMinute },
        { key: "bytes", period: 60, maximum: LIMITS.bytesPerMinute, amount: bytes },
        { key: "daily_bytes", period: 86400, maximum: LIMITS.bytesPerDay, amount: bytes },
        { key: `device_frames:${id}`, period: 60, maximum: LIMITS.deviceFramesPerMinute },
        { key: `device_bytes:${id}`, period: 60, maximum: LIMITS.deviceBytesPerMinute, amount: bytes },
      ]);
    } catch { this.rejectSocket(socket, state, 4008, "Rate limit"); return; }
    const destination = state.role === "host" ? this.deviceSocket(id) : this.hostSocket();
    if (!destination || this.state(destination)?.hostId !== state.hostId) {
      if (state.role === "device") this.rejectSocket(socket, state, 4001, "Host disconnected");
      // A host may have queued a last frame just before the peer left; no replay or storage.
      return;
    }
    try { destination.send(state.role === "host" ? message.slice(headerBytes) : routedRecord(id, message)); }
    catch {
      if (state.role === "device") this.disconnectHost(destination);
      else { this.close(destination, 4001, "Peer disconnected"); this.notifyHost("peer_disconnected", id); }
    }
  }

  private rejectSocket(socket: WebSocket, state: SocketState, code: number, reason: string): void {
    this.close(socket, code, reason);
    if (state.role === "host") {
      for (const device of this.sockets()) if (this.state(device)?.hostId === state.hostId) this.close(device, 4001, "Host disconnected");
    } else if (!this.deviceSocket(state.deviceId!) && this.state(this.hostSocket())?.hostId === state.hostId) {
      this.notifyHost("peer_disconnected", state.deviceId!);
    }
  }

  webSocketClose(socket: WebSocket, _code: number, _reason: string, _wasClean: boolean): void {
    const state = this.state(socket);
    if (!state?.active) return;
    this.rejectSocket(socket, state, 1000, "Closed");
  }

  webSocketError(socket: WebSocket): void {
    const state = this.state(socket);
    if (state?.active) this.rejectSocket(socket, state, 1011, "Connection error");
  }

  async alarm(): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM push_receipts WHERE expires_at <= ?", Date.now());
    const next = this.ctx.storage.sql.exec<{ expires_at: number | null }>("SELECT MIN(expires_at) AS expires_at FROM push_receipts").one().expires_at;
    if (next !== null) await this.ctx.storage.setAlarm(next);
  }

  private async push(device: Device | undefined, reference: string, encrypted?: EncryptedNotification): Promise<Response> {
    if (!device) return failure(404, "not_found");
    if (!pushAvailable(this.env)) return failure(503, "push_unavailable");
    if (!device.push_token || !device.push_env) return failure(409, "push_not_registered");
    if (!pushEnvironmentAllowed(this.env, device.push_env)) return failure(409, "push_environment_not_allowed");
    const now = Date.now();
    this.ctx.storage.sql.exec("DELETE FROM push_receipts WHERE expires_at < ?", now);
    const previous = this.ctx.storage.sql.exec<{ status: string }>("SELECT status FROM push_receipts WHERE device_id = ? AND reference = ?", device.id, reference).toArray()[0];
    if (previous) return json({ status: previous.status, duplicate: true }, 202);
    this.spend([
      { key: "pushes", period: 60, maximum: LIMITS.pushesPerMinute },
      { key: "daily_pushes", period: 86400, maximum: LIMITS.pushesPerDay },
      { key: `device_pushes:${device.id}`, period: 60, maximum: LIMITS.devicePushesPerMinute },
    ]);
    this.ctx.storage.sql.exec("INSERT INTO push_receipts (device_id, reference, status, expires_at) VALUES (?, ?, 'pending', ?)", device.id, reference, now + 86400_000);
    if (await this.ctx.storage.getAlarm() === null) await this.ctx.storage.setAlarm(now + 86400_000);
    if (!await this.env.ADMISSION.getByName("service").push()) {
      this.ctx.storage.sql.exec("DELETE FROM push_receipts WHERE device_id = ? AND reference = ?", device.id, reference);
      return failure(429, "push_capacity_reached");
    }
    // Authentication may have changed while waiting for the global quota.
    const currentDevice = this.device(device.id);
    if (!currentDevice || currentDevice.push_token !== device.push_token || currentDevice.push_env !== device.push_env) return failure(409, "push_registration_changed");
    const result = await sendPush(this.env, device.push_token, device.push_env, reference, encrypted);
    const { status } = result;
    // UPDATE cannot recreate a receipt if the device was revoked while APNs was in flight.
    this.ctx.storage.sql.exec("UPDATE push_receipts SET status = ?, stage = ?, apns_status = ?, reason = ? WHERE device_id = ? AND reference = ?",
      status, result.stage, result.apns_status, result.reason, device.id, reference);
    if (status === "unregistered") this.ctx.storage.sql.exec(
      "UPDATE devices SET push_token = NULL, push_env = NULL WHERE id = ? AND push_token = ? AND push_env = ?",
      device.id, device.push_token, device.push_env,
    );
    return json({ status }, status === "accepted" ? 202 : 502);
  }
}
