import { env, exports } from "cloudflare:workers";
import { reset, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { newToken } from "../src/protocol";
import { verifyTicket } from "../src/setup-ticket";

type Intent = { ticket: string; intent_id: string; owner_token: string; expires_at: number };
type Host = { installation_id: string; host_token: string };
let count = 0;
function request(path: string, method = "GET", token?: string, body?: unknown, ticket?: string) {
  return exports.default.fetch(`https://relay.test${path}`, { method, headers: {
    "CF-Connecting-IP": `192.0.${Math.floor(++count / 250)}.${count % 250}`,
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...(ticket ? { "X-Hermes-Setup": ticket } : {}),
    ...(body ? { "Content-Type": "application/json" } : {}),
  }, ...(body ? { body: JSON.stringify(body) } : {}) });
}
async function create(): Promise<Intent> {
  const response = await request("/v1/pairing/intents", "POST", undefined, { phone_public_key: newToken() });
  expect(response.status).toBe(201);
  return response.json();
}
async function host(): Promise<Host> {
  return (await request("/v1/installations", "POST", undefined, {})).json();
}
function claimBody(host: Host) {
  return { installation_id: host.installation_id, claim_id: crypto.randomUUID(), claim_token: newToken(), host_public_key: newToken(),
    host_name: "Hermes Mac", commitment: newToken() };
}
type Claim = ReturnType<typeof claimBody>;
const path = (intent: Intent) => `/v1/pairing/${intent.intent_id}`;
async function add(intent: Intent, h: Host, c: Claim) {
  const response = await request(path(intent) + "/claims", "POST", h.host_token, c, intent.ticket);
  expect(response.status).toBe(200);
}
async function put(intent: Intent, c: Claim, action: string, body: unknown, phone = false) {
  return request(`${path(intent)}/claims/${c.claim_id}/${action}`, "PUT", phone ? intent.owner_token : c.claim_token, body, intent.ticket);
}
beforeEach(() => { vi.spyOn(globalThis, "fetch").mockImplementation(async () => { throw new Error("Unexpected external request"); }); });
afterEach(async () => { await reset(); vi.restoreAllMocks(); });

describe("phone-bound setup broker", () => {
  it("retries device provisioning without rotating credentials or creating another device", async () => {
    const h = await host(), id = crypto.randomUUID(), token = newToken();
    const resource = `/v1/installations/${h.installation_id}/devices/${id}`;
    for (let i = 0; i < 2; i++) expect((await request(resource, "PUT", h.host_token, { device_token: token })).status).toBe(200);
    expect((await request(resource, "PUT", h.host_token, { device_token: newToken() })).status).toBe(409);
    expect((await request(resource, "PUT", newToken(), { device_token: token })).status).toBe(401);
    const response = await request(`/v1/installations/${h.installation_id}/devices`, "GET", h.host_token);
    expect(await response.json()).toMatchObject({ devices: [{ device_id: id }] });
  });
  it("signs exact phone, service, and expiry; rejects modified and wrong-service tickets", async () => {
    const intent = await create();
    const verified = await verifyTicket(env, intent.ticket, "https://relay.test");
    expect(verified.intent_id).toBe(intent.intent_id);
    await expect(verifyTicket(env, intent.ticket, "https://other.test")).rejects.toThrow();
    const parts = intent.ticket.split(".");
    parts[1] = parts[1].slice(0, -1) + (parts[1].endsWith("A") ? "B" : "A");
    await expect(verifyTicket(env, parts.join("."), "https://relay.test")).rejects.toThrow();
    expect((await request(path(intent), "GET", newToken(), undefined, intent.ticket)).status).toBe(401);
    expect((await request(path(intent), "GET", intent.owner_token, undefined, "HJ1.bad.bad")).status).toBe(400);
  });
  it("requires an existing host credential and never exposes another claim token or the owner token", async () => {
    const intent = await create(), h = await host(), c = claimBody(h);
    expect((await request(path(intent) + "/claims", "POST", newToken(), c, intent.ticket)).status).toBe(401);
    await add(intent, h, c);
    const response = await request(path(intent), "GET", intent.owner_token, undefined, intent.ticket);
    const value = JSON.stringify(await response.json());
    expect(value).not.toContain(c.claim_token); expect(value).not.toContain(intent.owner_token); expect(value).not.toContain("token_hash");
    expect((await request(path(intent), "GET", c.claim_token, undefined, intent.ticket)).status).toBe(401);
  });
  it("enforces commit/key/reveal/confirm/enrollment order, role boundaries and immutable retries", async () => {
    const intent = await create(), h = await host(), c = claimBody(h);
    await add(intent, h, c);
    expect((await put(intent, c, "reveal", { host_ephemeral: newToken() })).status).toBe(409);
    expect((await put(intent, c, "key", { phone_ephemeral: newToken() })).status).toBe(401);
    const phone = newToken(), reveal = newToken();
    expect((await put(intent, c, "key", { phone_ephemeral: phone }, true)).status).toBe(200);
    expect((await put(intent, c, "key", { phone_ephemeral: phone }, true)).status).toBe(200);
    expect((await put(intent, c, "key", { phone_ephemeral: newToken() }, true)).status).toBe(409);
    expect((await put(intent, c, "reveal", { host_ephemeral: reveal })).status).toBe(200);
    expect((await put(intent, c, "reveal", { host_ephemeral: newToken() })).status).toBe(409);
    expect((await put(intent, c, "enrollment", { envelope: newToken() + newToken() })).status).toBe(409);
    expect((await put(intent, c, "confirm", { confirmation: newToken() })).status).toBe(401);
    expect((await put(intent, c, "confirm", { confirmation: newToken() }, true)).status).toBe(200);
    expect((await put(intent, c, "enrollment", { envelope: newToken() + newToken() })).status).toBe(200);
    await add(intent, h, c); // Re-running the SAME host command may resume after confirmation.
  });
  it("keeps competing claims separate and atomically permits only one selection", async () => {
    const intent = await create(), h = await host(), a = claimBody(h), b = claimBody(h);
    await Promise.all([add(intent, h, a), add(intent, h, b)]);
    for (const c of [a, b]) {
      await put(intent, c, "key", { phone_ephemeral: newToken() }, true);
      await put(intent, c, "reveal", { host_ephemeral: newToken() });
    }
    const results = await Promise.all([a, b].map(c => put(intent, c, "confirm", { confirmation: newToken() }, true)));
    expect(results.map(x => x.status).sort()).toEqual([200, 409]);
    expect((await request(path(intent) + "/claims", "POST", h.host_token, claimBody(h), intent.ticket)).status).toBe(409);
  });
  it("caps claims and does not refund the budget by resetting a claim", async () => {
    const intent = await create(), h = await host(), first = claimBody(h);
    await add(intent, h, first); await add(intent, h, claimBody(h)); await add(intent, h, claimBody(h));
    expect((await request(path(intent) + "/claims", "POST", h.host_token, claimBody(h), intent.ticket)).status).toBe(429);
    expect((await request(path(intent) + "/claims", "POST", h.host_token, { ...first, commitment: newToken() }, intent.ticket)).status).toBe(409);
  });
  it("deletes push/cryptographic payload state on cancel and all state on expiry", async () => {
    const intent = await create(), h = await host(), c = claimBody(h);
    await add(intent, h, c);
    await put(intent, c, "key", { phone_ephemeral: newToken() }, true);
    await request(path(intent) + "/cancel", "POST", intent.owner_token, {}, intent.ticket);
    const response = await request(`${path(intent)}/claims/${c.claim_id}`, "GET", c.claim_token, undefined, intent.ticket);
    expect(await response.json()).toMatchObject({ status: "cancelled" });
    expect((await put(intent, c, "reveal", { host_ephemeral: newToken() })).status).toBe(409);
    await runDurableObjectAlarm(env.SETUP_INTENTS.getByName(intent.intent_id));
    expect((await request(path(intent), "GET", intent.owner_token, undefined, intent.ticket)).status).toBe(404);
  });
  it("enforces a shorter comparison deadline independently from the ticket expiry", async () => {
    const intent = await create(), h = await host(), c = claimBody(h);
    await add(intent, h, c); await put(intent, c, "key", { phone_ephemeral: newToken() }, true);
    await runInDurableObject(env.SETUP_INTENTS.getByName(intent.intent_id), (_object, state) => {
      const row = state.storage.sql.exec<{ value: string }>("SELECT value FROM claims").one();
      const value = JSON.parse(row.value); value.deadline = Date.now() / 1000 - 1;
      state.storage.sql.exec("UPDATE claims SET value=?", JSON.stringify(value));
    });
    expect((await put(intent, c, "reveal", { host_ephemeral: newToken() })).status).toBe(410);
  });
  it("sends one credential-free setup doorbell, including registration after readiness", async () => {
    vi.mocked(fetch).mockResolvedValue(new Response(null, { status: 200 }));
    const intent = await create(), h = await host();
    await add(intent, h, claimBody(h));
    const body = { apns_token: "ab".repeat(32), environment: "sandbox" };
    await request(path(intent) + "/push", "PUT", intent.owner_token, body, intent.ticket);
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    const payload = JSON.parse(vi.mocked(fetch).mock.calls[0][1]!.body as string);
    expect(Object.keys(payload).sort()).toEqual(["aps", "pairing_ready"]);
    expect(payload.pairing_ready).toBe(intent.intent_id);
    await add(intent, h, claimBody(h));
    await request(path(intent) + "/push", "PUT", intent.owner_token, body, intent.ticket);
    expect(fetch).toHaveBeenCalledTimes(1);
  });
});
