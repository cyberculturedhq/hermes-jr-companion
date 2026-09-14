import { env, exports } from "cloudflare:workers";
import { abortAllDurableObjects, evictDurableObject, reset, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { sendPush } from "../src/apns";
import { LIMITS, newToken, routedRecord, tokenHash } from "../src/protocol";

type Installation = { installation_id: string; host_token: string };
type Device = { device_id: string; device_token: string };
let requestIndex = 0;
const sockets: WebSocket[] = [];

function request(path: string, method = "GET", token?: string, body?: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return exports.default.fetch(`https://relay.test${path}`, {
    method,
    headers: {
      "CF-Connecting-IP": `198.51.${Math.floor(++requestIndex / 250)}.${requestIndex % 250}`,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...headers,
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
}
const base = (install: Installation) => `/v1/installations/${install.installation_id}`;
const devicePath = (install: Installation, device: Device) => `${base(install)}/devices/${device.device_id}`;

async function installation(): Promise<Installation> {
  const response = await request("/v1/installations", "POST", undefined, {});
  expect(response.status).toBe(201);
  return response.json();
}

async function device(install: Installation): Promise<Device> {
  const response = await request(`${base(install)}/devices`, "POST", install.host_token, {});
  expect(response.status).toBe(201);
  return response.json();
}

async function socket(path: string, token: string): Promise<WebSocket> {
  const response = await request(path, "GET", token, undefined, { Upgrade: "websocket" });
  expect(response.status, JSON.stringify(await (response.status === 101 ? Promise.resolve(null) : response.json()))).toBe(101);
  const ws = response.webSocket!;
  ws.binaryType = "arraybuffer";
  ws.accept();
  sockets.push(ws);
  return ws;
}

function nextMessage(ws: WebSocket): Promise<string | ArrayBuffer> {
  return new Promise((resolve) => ws.addEventListener("message", (event) => resolve(event.data), { once: true }));
}
function nextClose(ws: WebSocket): Promise<number> {
  return new Promise((resolve) => ws.addEventListener("close", (event) => resolve(event.code), { once: true }));
}

beforeEach(() => {
  // Any accidental external request is a test failure. APNs tests replace this implementation.
  vi.spyOn(globalThis, "fetch").mockImplementation(async () => { throw new Error("Unexpected external request"); });
});
afterEach(async () => {
  for (const ws of sockets.splice(0)) { try { ws.close(); } catch {} }
  await reset();
  vi.restoreAllMocks();
});

describe("installation authentication", () => {
  it("issues independent random credentials and stores only hashes", async () => {
    const install = await installation();
    const other = await installation();
    const phone = await device(install);
    expect(install.installation_id).not.toBe(other.installation_id);
    expect(install.host_token).not.toBe(other.host_token);
    expect(install.host_token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const stored = await runInDurableObject(env.INSTALLATIONS.getByName(install.installation_id), (_instance, state) => ({
      installation: state.storage.sql.exec<{ host_hash: string }>("SELECT host_hash FROM installation").one(),
      device: state.storage.sql.exec<{ token_hash: string }>("SELECT token_hash FROM devices").one(),
    }));
    expect(stored.installation.host_hash).toBe(await tokenHash(install.host_token));
    expect(stored.device.token_hash).toBe(await tokenHash(phone.device_token));
    expect(JSON.stringify(stored)).not.toContain(install.host_token);
    expect((await request(`${base(install)}/devices`, "POST", other.host_token, {})).status).toBe(401);
    expect((await request(`${base(install)}/devices`, "POST", phone.device_token, {})).status).toBe(401);
    expect((await request(`${base(install)}/devices`, "GET")).status).toBe(401);
  });

  it("does not allow a device credential to administer another device or installation", async () => {
    const install = await installation();
    const phone = await device(install);
    const second = await device(install);
    expect((await request(`${devicePath(install, second)}/push`, "PUT", phone.device_token, { apns_token: "a".repeat(64), environment: "sandbox" })).status).toBe(401);
    expect((await request(devicePath(install, phone), "DELETE", phone.device_token)).status).toBe(403);
    expect((await request(base(install), "DELETE", phone.device_token)).status).toBe(401);
    expect((await request(`${devicePath(install, phone)}/connect`, "GET", install.host_token, undefined, { Upgrade: "websocket" })).status).toBe(403);
  });

  it("caps concurrent device provisioning and permits reuse of a revoked slot", async () => {
    const install = await installation();
    const responses = await Promise.all(Array.from({ length: LIMITS.devices + 3 }, () => request(`${base(install)}/devices`, "POST", install.host_token, {})));
    expect(responses.filter((response) => response.status === 201)).toHaveLength(LIMITS.devices);
    expect(responses.filter((response) => response.status === 409)).toHaveLength(3);
    const phone: Device = await responses.find((response) => response.status === 201)!.json();
    expect((await request(devicePath(install, phone), "DELETE", install.host_token)).status).toBe(200);
    await device(install);
    expect((await request(`${devicePath(install, phone)}/push`, "DELETE", phone.device_token)).status).toBe(401);
  });

  it("enforces the configured public registration rate limiter", async () => {
    const ip = "203.0.113.77";
    const responses = [];
    for (let i = 0; i < 6; i++) responses.push(await request("/v1/installations", "POST", undefined, {}, { "CF-Connecting-IP": ip }));
    expect(responses.slice(0, 5).map((response) => response.status)).toEqual([201, 201, 201, 201, 201]);
    expect(responses[5].status).toBe(429);
    expect(responses[5].headers.get("Retry-After")).toBe("60");
  });

  it("rejects large/chunked bodies, extra data, plaintext transport and credential URLs", async () => {
    expect((await request("/v1/installations", "POST", undefined, { text: "private" })).status).toBe(400);
    const bytes = new TextEncoder().encode(JSON.stringify({ value: "x".repeat(5000) }));
    const stream = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(bytes.slice(0, 4000)); controller.enqueue(bytes.slice(4000)); controller.close(); } });
    const response = await exports.default.fetch("https://relay.test/v1/installations", { method: "POST", headers: { "Content-Type": "application/json" }, body: stream });
    expect(response.status).toBe(413);
    expect((await exports.default.fetch("http://relay.test/health")).status).toBe(400);
    expect((await request("/v1/capabilities?token=private")).status).toBe(400);
    expect((await request("/v1/capabilities", "GET", undefined, undefined, { Origin: "https://evil.test" })).status).toBe(400);
  });
});

describe("opaque WebSocket forwarding", () => {
  it("forwards exact ciphertext only to its peer, including after hibernation", async () => {
    const install = await installation();
    const first = await device(install);
    const second = await device(install);
    const host = await socket(`${base(install)}/host`, install.host_token);
    const joined = nextMessage(host);
    const one = await socket(`${devicePath(install, first)}/connect`, first.device_token);
    expect(JSON.parse(await joined as string)).toEqual({ type: "peer_connected", device_id: first.device_id });
    const joinedSecond = nextMessage(host);
    const two = await socket(`${devicePath(install, second)}/connect`, second.device_token);
    await joinedSecond;
    await evictDurableObject(env.INSTALLATIONS.getByName(install.installation_id));
    // A malicious device-supplied routing header remains opaque payload. The outer
    // header must still identify the authenticated first device.
    const ciphertext = routedRecord(second.device_id, crypto.getRandomValues(new Uint8Array(240)).buffer);
    const toHost = nextMessage(host);
    one.send(ciphertext);
    expect(new Uint8Array(await toHost as ArrayBuffer)).toEqual(new Uint8Array(routedRecord(first.device_id, ciphertext)));
    const firstUnexpected = vi.fn();
    one.addEventListener("message", firstUnexpected);
    const toSecond = nextMessage(two);
    host.send(routedRecord(second.device_id, ciphertext));
    expect(new Uint8Array(await toSecond as ArrayBuffer)).toEqual(new Uint8Array(ciphertext));
    expect(firstUnexpected).not.toHaveBeenCalled();
    const maximum = new Uint8Array(LIMITS.ciphertextBytes).buffer;
    const atLimit = nextMessage(two);
    host.send(routedRecord(second.device_id, maximum));
    expect((await atLimit as ArrayBuffer).byteLength).toBe(LIMITS.ciphertextBytes);
    const tables = await runInDurableObject(env.INSTALLATIONS.getByName(install.installation_id), (_instance, state) => state.storage.sql.exec<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table'").toArray());
    expect(tables.map((table) => table.name).filter((name) => !name.startsWith("_"))).toEqual(expect.arrayContaining(["installation", "devices", "budgets", "push_receipts"]));
  });

  it("rejects duplicate connections and closes devices with the host", async () => {
    const install = await installation();
    const phone = await device(install);
    expect((await request(`${devicePath(install, phone)}/connect`, "GET", phone.device_token, undefined, { Upgrade: "websocket" })).status).toBe(409);
    const host = await socket(`${base(install)}/host`, install.host_token);
    const joined = nextMessage(host);
    const mobile = await socket(`${devicePath(install, phone)}/connect`, phone.device_token);
    await joined;
    expect((await request(`${base(install)}/host`, "GET", install.host_token, undefined, { Upgrade: "websocket" })).status).toBe(409);
    expect((await request(`${devicePath(install, phone)}/connect`, "GET", phone.device_token, undefined, { Upgrade: "websocket" })).status).toBe(409);
    const closed = nextClose(mobile);
    host.close();
    expect(await closed).toBe(4001);
  });

  it("revokes an active device without dropping a different peer", async () => {
    const install = await installation();
    const first = await device(install);
    const second = await device(install);
    const host = await socket(`${base(install)}/host`, install.host_token);
    const joined = nextMessage(host);
    const one = await socket(`${devicePath(install, first)}/connect`, first.device_token);
    await joined;
    const joinedSecond = nextMessage(host);
    const two = await socket(`${devicePath(install, second)}/connect`, second.device_token);
    await joinedSecond;
    const closed = nextClose(one);
    const left = nextMessage(host);
    expect((await request(devicePath(install, first), "DELETE", install.host_token)).status).toBe(200);
    expect(await closed).toBe(4003);
    expect(JSON.parse(await left as string)).toEqual({ type: "peer_disconnected", device_id: first.device_id });
    const delivered = nextMessage(host);
    two.send(new Uint8Array([3, 2, 1]).buffer);
    expect(new Uint8Array(await delivered as ArrayBuffer)).toEqual(new Uint8Array(routedRecord(second.device_id, new Uint8Array([3, 2, 1]).buffer)));
  });

  it.each(["plaintext", "oversize", "unknown_device", "rate"])("closes invalid %s traffic", async (kind) => {
    const install = await installation();
    const phone = await device(install);
    const host = await socket(`${base(install)}/host`, install.host_token);
    const joined = nextMessage(host);
    const mobile = await socket(`${devicePath(install, phone)}/connect`, phone.device_token);
    await joined;
    if (kind === "rate") {
      await runInDurableObject(env.INSTALLATIONS.getByName(install.installation_id), (_instance, state) => {
        state.storage.sql.exec("INSERT INTO budgets VALUES ('frames', ?, ?)", Math.floor(Date.now() / 60000), LIMITS.framesPerMinute);
      });
      await evictDurableObject(env.INSTALLATIONS.getByName(install.installation_id));
    }
    const closingSocket = kind === "unknown_device" ? host : mobile;
    const closed = nextClose(closingSocket);
    if (kind === "plaintext") mobile.send("content is not allowed");
    if (kind === "oversize") mobile.send(new Uint8Array(LIMITS.ciphertextBytes + 1).buffer);
    if (kind === "unknown_device") host.send(routedRecord(crypto.randomUUID(), new Uint8Array([1]).buffer));
    if (kind === "rate") mobile.send(new Uint8Array([1]).buffer);
    expect(await closed).toBe({ plaintext: 1003, oversize: 1009, unknown_device: 4003, rate: 4008 }[kind]);
  });

  it("allows a 25 MiB photo encoded as JSON to finish within one minute", async () => {
    const install = await installation();
    const phone = await device(install);
    const host = await socket(`${base(install)}/host`, install.host_token);
    const joined = nextMessage(host);
    const mobile = await socket(`${devicePath(install, phone)}/connect`, phone.device_token);
    await joined;
    // Seed the already forwarded bulk, then pass the final maximum-size record through
    // the real DO. Base64 and encrypted chunk overhead must fit the same minute budget.
    const priorBytes = Math.ceil((25 * 1024 * 1024) / 3) * 4;
    await runInDurableObject(env.INSTALLATIONS.getByName(install.installation_id), (_instance, state) => {
      const minute = Math.floor(Date.now() / 60000);
      state.storage.sql.exec("INSERT INTO budgets VALUES (?, ?, ?)", "bytes", minute, priorBytes);
      state.storage.sql.exec("INSERT INTO budgets VALUES (?, ?, ?)", `device_bytes:${phone.device_id}`, minute, priorBytes);
    });
    const delivered = nextMessage(host);
    mobile.send(new Uint8Array(LIMITS.ciphertextBytes).buffer);
    expect((await delivered as ArrayBuffer).byteLength).toBe(LIMITS.routingHeaderBytes + LIMITS.ciphertextBytes);
  });

  it.each(["device", "installation", "daily"])("enforces the %s byte budget after hibernation", async (scope) => {
    const install = await installation();
    const phone = await device(install);
    const host = await socket(`${base(install)}/host`, install.host_token);
    const joined = nextMessage(host);
    const mobile = await socket(`${devicePath(install, phone)}/connect`, phone.device_token);
    await joined;
    const key = scope === "device" ? `device_bytes:${phone.device_id}` : scope === "daily" ? "daily_bytes" : "bytes";
    const maximum = scope === "device" ? LIMITS.deviceBytesPerMinute : scope === "daily" ? LIMITS.bytesPerDay : LIMITS.bytesPerMinute;
    const period = scope === "daily" ? 86400 : 60;
    const stub = env.INSTALLATIONS.getByName(install.installation_id);
    await runInDurableObject(stub, (_instance, state) => {
      state.storage.sql.exec("INSERT INTO budgets VALUES (?, ?, ?)", key, Math.floor(Date.now() / (period * 1000)), maximum - LIMITS.ciphertextBytes);
    });
    await evictDurableObject(stub);
    const delivered = nextMessage(host);
    mobile.send(new Uint8Array(LIMITS.ciphertextBytes).buffer);
    expect((await delivered as ArrayBuffer).byteLength).toBe(LIMITS.routingHeaderBytes + LIMITS.ciphertextBytes);
    const closed = nextClose(mobile);
    mobile.send(new Uint8Array([1]).buffer);
    expect(await closed).toBe(4008);
  });
});

describe("generic APNs notifications", () => {
  it("constructs runtime-valid provider requests and refuses to forward redirects", async () => {
    let redirectMode: string | undefined;
    vi.mocked(fetch).mockImplementation(async (input, init) => {
      // A fetch spy alone bypasses runtime validation (Workers rejects redirect:error).
      const outbound = new Request(input, init);
      redirectMode = outbound.redirect;
      return Response.redirect("https://untrusted.test/PRIVATE_DESTINATION", 302);
    });
    expect(await sendPush(env, "a".repeat(64), "sandbox", newToken())).toEqual({ status: "failed", stage: "transport", apns_status: null, reason: null });
    expect(redirectMode).toBe("manual");
    expect(fetch).toHaveBeenCalledTimes(1);
  });
  it("sends generic content without a relay connection, deduplicates, and caches the signing token", async () => {
    const install = await installation();
    const phone = await device(install);
    const token = "ab".repeat(32);
    const path = `${devicePath(install, phone)}/push`;
    expect((await request(path, "PUT", phone.device_token, { apns_token: token, environment: "sandbox" })).status).toBe(200);
    const sent: { url: string; headers: Headers; body: unknown }[] = [];
    vi.mocked(fetch).mockImplementation(async (input, init) => {
      expect(new Request(input, init).redirect).toBe("manual");
      sent.push({ url: String(input), headers: new Headers(init?.headers), body: JSON.parse(init!.body as string) });
      return new Response(null, { status: 200 });
    });
    const reference = newToken();
    expect((await request(path, "POST", install.host_token, { reference })).status).toBe(202);
    const duplicate = await request(path, "POST", install.host_token, { reference });
    expect(await duplicate.json()).toEqual({ status: "accepted", duplicate: true });
    await evictDurableObject(env.APNS_AUTH.getByName(`${env.APNS_TEAM_ID}:${env.APNS_KEY_ID}`));
    expect((await request(path, "POST", install.host_token, { reference: newToken() })).status).toBe(202);
    expect(sent).toHaveLength(2);
    expect(sent[0].url).toBe(`https://api.sandbox.push.apple.com/3/device/${token}`);
    expect(sent[0].headers.get("apns-topic")).toBe("test.hermes.jr");
    expect(sent[0].headers.get("authorization")).toBe(sent[1].headers.get("authorization"));
    expect(sent[0].body).toEqual({
      aps: { alert: { title: "Hermes Jr.", body: "You have a new notification. Open the app for details." }, sound: "default" }, reference,
    });
    expect((await request(path, "POST", phone.device_token, { reference: newToken() })).status).toBe(403);
    expect((await request(path, "POST", install.host_token, { reference: newToken(), text: "private" })).status).toBe(400);
  });

  it("forwards only bounded encrypted previews and the generic fallback to APNs", async () => {
    const install = await installation(), phone = await device(install);
    const path = `${devicePath(install, phone)}/push`;
    await request(path, "PUT", phone.device_token, { apns_token: "ab".repeat(32), environment: "sandbox" });
    const encrypted = { v: 1, kid: "A".repeat(22), data: "A".repeat(1403) };
    const reference = newToken();
    vi.mocked(fetch).mockImplementation(async (_input, init) => {
      const body = JSON.parse(init!.body as string);
      expect(body).toEqual({ aps: { alert: { title: "Hermes Jr.", body: "You have a new notification. Open the app for details." }, sound: "default", "mutable-content": 1 }, reference, encrypted });
      expect(new TextEncoder().encode(init!.body as string).length).toBeLessThan(4096);
      return new Response(null, { status: 200 });
    });
    expect((await request(path, "POST", install.host_token, { reference, encrypted })).status).toBe(202);
    for (const invalid of [{ ...encrypted, v: 2 }, { ...encrypted, data: "small" }, { ...encrypted, profile: "private" }, null]) {
      expect((await request(path, "POST", install.host_token, { reference: newToken(), encrypted: invalid })).status).toBe(400);
    }
    expect((await request(path, "POST", install.host_token, { reference: newToken(), encrypted, title: "private" })).status).toBe(400);
  });

  it("validates references, limits push bursts, and removes expired APNs registrations", async () => {
    const install = await installation();
    const phone = await device(install);
    const path = `${devicePath(install, phone)}/push`;
    await request(path, "PUT", phone.device_token, { apns_token: "c".repeat(64), environment: "production" });
    expect((await request(path, "POST", install.host_token, { reference: "session-secret" })).status).toBe(400);
    vi.mocked(fetch).mockResolvedValue(new Response(null, { status: 410 }));
    expect((await request(path, "POST", install.host_token, { reference: newToken() })).status).toBe(502);
    expect((await request(path, "POST", install.host_token, { reference: newToken() })).status).toBe(409);
    await request(path, "PUT", phone.device_token, { apns_token: "d".repeat(64), environment: "production" });
    vi.mocked(fetch).mockImplementation(async () => new Response(null, { status: 200 }));
    for (let i = 1; i < LIMITS.devicePushesPerMinute; i++) expect((await request(path, "POST", install.host_token, { reference: newToken() })).status).toBe(202);
    expect((await request(path, "POST", install.host_token, { reference: newToken() })).status).toBe(429);
  });

  it("reports missing APNs configuration without enabling a partial integration", async () => {
    const response = await worker.fetch(new Request("https://relay.test/v1/capabilities"), { ...env, APNS_PRIVATE_KEY: "" });
    expect(await response.json()).toMatchObject({ protocol_version: 1, push: false });
    const unavailableLimiter = await worker.fetch(new Request("https://relay.test/v1/installations", { method: "POST" }), { ...env, INSTALL_RATE_LIMITER: undefined } as unknown as Env);
    expect(unavailableLimiter.status).toBe(503);
  });

  it("refuses an APNs environment outside the signing key scope without making a request", async () => {
    expect(await sendPush({ ...env, APNS_ENVIRONMENT: "sandbox" }, "a".repeat(64), "production", newToken())).toEqual({
      status: "unavailable", stage: null, apns_status: null, reason: null,
    });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("persists only safe Apple diagnostics and exposes them only to the matching host", async () => {
    const install = await installation();
    const phone = await device(install);
    const otherPhone = await device(install);
    const otherInstall = await installation();
    const path = `${devicePath(install, phone)}/push`;
    const reference = newToken();
    const receiptPath = `${path}/receipts/${reference}`;
    await request(path, "PUT", phone.device_token, { apns_token: "a".repeat(64), environment: "sandbox" });
    vi.mocked(fetch).mockImplementation(async () => Response.json({ reason: "InvalidProviderToken", detail: "PRIVATE_RESPONSE_TEXT", token: "PRIVATE_TOKEN" },
      { status: 403, headers: { "private-header": "PRIVATE_HEADER" } }));
    const posted = await request(path, "POST", install.host_token, { reference });
    expect(posted.status).toBe(502);
    expect(await posted.json()).toEqual({ status: "failed" });
    expect((await request(receiptPath, "GET")).status).toBe(401);
    expect((await request(receiptPath, "GET", phone.device_token)).status).toBe(403);
    expect((await request(receiptPath, "GET", otherPhone.device_token)).status).toBe(401);
    expect((await request(receiptPath, "GET", otherInstall.host_token)).status).toBe(401);
    const receipt = await request(receiptPath, "GET", install.host_token);
    expect(receipt.status).toBe(200);
    expect(receipt.headers.get("Cache-Control")).toBe("no-store");
    expect(await receipt.json()).toEqual({ status: "failed", stage: "apns", apns_status: 403, reason: "InvalidProviderToken", expires_at: expect.any(Number) });
    const stored = await runInDurableObject(env.INSTALLATIONS.getByName(install.installation_id), (_instance, state) => state.storage.sql.exec("SELECT * FROM push_receipts").toArray());
    expect(JSON.stringify(stored)).not.toContain("PRIVATE_");
    expect(await (await request(path, "POST", install.host_token, { reference })).json()).toEqual({ status: "failed", duplicate: true });
    expect(fetch).toHaveBeenCalledTimes(1);
    await request(devicePath(install, phone), "DELETE", install.host_token);
    expect((await request(receiptPath, "GET", install.host_token)).status).toBe(404);
  });

  it("distinguishes signing failure from an unknown transport outcome without exposing errors", async () => {
    // Do not monkey-patch a native DurableObjectNamespace method: workerd's teardown
    // cannot safely restore that property. A typed proxy provides the isolated fault.
    const failingAuth = new Proxy(env.APNS_AUTH, {
      get(target, property, receiver) {
        if (property === "getByName") return () => { throw new Error("PRIVATE_SIGNING_ERROR"); };
        return Reflect.get(target, property, receiver);
      },
    });
    expect(await sendPush({ ...env, APNS_AUTH: failingAuth }, "a".repeat(64), "sandbox", newToken())).toEqual({ status: "failed", stage: "signing", apns_status: null, reason: null });
    expect(fetch).not.toHaveBeenCalled();
    vi.mocked(fetch).mockRejectedValue(new Error("PRIVATE_URL_AND_TOKEN"));
    expect(await sendPush(env, "a".repeat(64), "sandbox", newToken())).toEqual({ status: "failed", stage: "transport", apns_status: null, reason: null });
  });

  it.each(["unknown", "malformed", "oversize", "broken_stream"])("discards %s Apple error content while retaining the HTTP result", async (kind) => {
    const cancel = vi.fn();
    const body = kind === "unknown" ? '{"reason":"PRIVATE_TOKEN_VALUE"}' : kind === "malformed" ? 'PRIVATE_RAW_TEXT' : '{"reason":"InvalidProviderToken","padding":"' + "x".repeat(1100) + '"}';
    vi.mocked(fetch).mockImplementation(async () => new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        if (kind === "broken_stream") controller.error(new Error("PRIVATE_STREAM_ERROR"));
        else {
          const bytes = new TextEncoder().encode(body);
          controller.enqueue(bytes.slice(0, 500));
          controller.enqueue(bytes.slice(500));
          if (kind !== "oversize") controller.close();
        }
      }, cancel,
    }), { status: 403 }));
    expect(await sendPush(env, "a".repeat(64), "sandbox", newToken())).toEqual({ status: "failed", stage: "apns", apns_status: 403, reason: null });
    if (kind === "oversize") expect(cancel).toHaveBeenCalledOnce();
  });

  it("allows read-only pending inspection without duplicating delivery and revocation wins the in-flight update", async () => {
    const install = await installation();
    const phone = await device(install);
    const path = `${devicePath(install, phone)}/push`;
    const reference = newToken();
    const receiptPath = `${path}/receipts/${reference}`;
    await request(path, "PUT", phone.device_token, { apns_token: "a".repeat(64), environment: "sandbox" });
    vi.mocked(fetch).mockImplementation(async () => {
      // Dispatch actual incoming requests before the provider reply completes. Keeping
      // the continuation in this request context avoids a cross-context mock Promise.
      expect(await (await request(receiptPath, "GET", install.host_token)).json()).toEqual({ status: "pending", stage: null, apns_status: null, reason: null, expires_at: expect.any(Number) });
      expect(await (await request(path, "POST", install.host_token, { reference })).json()).toEqual({ status: "pending", duplicate: true });
      await request(devicePath(install, phone), "DELETE", install.host_token);
      return new Response(null, { status: 200 });
    });
    expect((await request(path, "POST", install.host_token, { reference })).status).toBe(202);
    expect(fetch).toHaveBeenCalledTimes(1);
    expect((await request(receiptPath, "GET", install.host_token)).status).toBe(404);
    expect(await runInDurableObject(env.INSTALLATIONS.getByName(install.installation_id), (_instance, state) => state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM push_receipts").one().count)).toBe(0);
  });

  it("upgrades legacy receipt storage without inventing diagnostics and hides expired receipts", async () => {
    const install = await installation();
    const phone = await device(install);
    const stub = env.INSTALLATIONS.getByName(install.installation_id);
    const path = `${devicePath(install, phone)}/push`;
    const reference = newToken(), expired = newToken();
    await runInDurableObject(stub, (_instance, state) => {
      state.storage.sql.exec("DROP TABLE push_receipts; CREATE TABLE push_receipts (device_id TEXT NOT NULL, reference TEXT NOT NULL, status TEXT NOT NULL, expires_at INTEGER NOT NULL, PRIMARY KEY(device_id, reference));");
      state.storage.sql.exec("INSERT INTO push_receipts VALUES (?, ?, 'failed', ?)", phone.device_id, reference, Date.now() + 60_000);
      state.storage.sql.exec("INSERT INTO push_receipts VALUES (?, ?, 'accepted', ?)", phone.device_id, expired, Date.now() - 1000);
    });
    await abortAllDurableObjects();
    expect(await (await request(`${path}/receipts/${reference}`, "GET", install.host_token)).json()).toEqual({ status: "failed", stage: null, apns_status: null, reason: null, expires_at: expect.any(Number) });
    expect((await request(`${path}/receipts/${expired}`, "GET", install.host_token)).status).toBe(404);
    expect((await request(`${path}/receipts/${newToken()}`, "GET", install.host_token)).status).toBe(404);
    expect((await request(`${path}/receipts/invalid`, "GET", install.host_token)).status).toBe(404);
    await abortAllDurableObjects(); // The constructor upgrade must be idempotent.
    await request(path, "PUT", phone.device_token, { apns_token: "a".repeat(64), environment: "sandbox" });
    vi.mocked(fetch).mockResolvedValue(new Response(null, { status: 200 }));
    const fresh = newToken();
    expect((await request(path, "POST", install.host_token, { reference: fresh })).status).toBe(202);
    expect(await (await request(`${path}/receipts/${fresh}`, "GET", install.host_token)).json()).toEqual({ status: "accepted", stage: "apns", apns_status: 200, reason: null, expires_at: expect.any(Number) });
  });

  it("expires notification references through a durable alarm even when no new pushes arrive", async () => {
    const install = await installation();
    const phone = await device(install);
    const stub = env.INSTALLATIONS.getByName(install.installation_id);
    await runInDurableObject(stub, async (_instance, state) => {
      state.storage.sql.exec("INSERT INTO push_receipts (device_id, reference, status, expires_at) VALUES (?, ?, 'accepted', ?)", phone.device_id, newToken(), Date.now() - 1000);
      await state.storage.setAlarm(Date.now() + 1000);
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    expect(await runInDurableObject(stub, (_instance, state) => state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM push_receipts").one().count)).toBe(0);
  });
});
