import { pushAvailable } from "./apns";
import { exactKeys, failure, handleErrors, json, readJson, unwrap } from "./http";
import { bearer, LIMITS, newToken, sameHash, PROTOCOL_VERSION, tokenHash, UUID_PATTERN } from "./protocol";
import { issueTicket, verifyTicket, setupPublicKey, key32 } from "./setup-ticket";
import { setupPrompt } from "./setup-prompt";
import { companionRelease } from "./companion-release";
export { SetupIntent } from "./setup";
export { InstallationRelay } from "./installation";
export { ServiceAdmission } from "./admission";
export { APNsProviderToken } from "./apns";
export { AppAdmission } from "./app-admission";

export default {
  async fetch(request, env): Promise<Response> {
    return handleErrors(async () => {
      const url = new URL(request.url);
      if (url.protocol !== "https:" && !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) return failure(400, "https_required");
      // No credential-bearing URLs, user-chosen forward destinations, or browser cross-origin access.
      if (url.search || request.headers.has("Origin")) return failure(400, "unsupported_request");
      if (url.pathname === "/v1/operator/status" && request.method === "GET") {
        const token = bearer(request);
        if (!token || !env.OPERATOR_TOKEN || !sameHash(await tokenHash(token), await tokenHash(env.OPERATOR_TOKEN))) return failure(401, "unauthorized");
        return json(await env.ADMISSION.getByName("service").status());
      }
      if (env.RELAY_ENABLED !== "true") return failure(503, "service_paused");
      if (url.pathname === "/v1/capabilities" && request.method === "GET") {
        return json({ protocol_version: PROTOCOL_VERSION, push: pushAvailable(env), numeric_pairing: Boolean(env.SETUP_TICKET_PRIVATE_KEY), max_ciphertext_bytes: LIMITS.ciphertextBytes, registration_requires_ticket: env.APP_ATTEST_MODE==='required' });
      }
      if (url.pathname === "/health" && request.method === "GET") return json({ status: "ok" });
      // CF-Connecting-IP is set by Cloudflare at ingress; a shared fallback deliberately fails
      // closed for unidentified callers, and makes localhost limits real instead of bypassed.
      const ip = request.headers.get("CF-Connecting-IP") ?? "unidentified";
      if (url.pathname === "/v1/companion-release" && request.method === "GET") {
        if (!env.REQUEST_RATE_LIMITER || !(await env.REQUEST_RATE_LIMITER.limit({ key: `release:${ip}` })).success) return failure(429, "rate_limited");
        return companionRelease(request);
      }
      if (url.pathname === '/v1/app-attest/challenges' && request.method === 'POST') {
        if (env.APP_ATTEST_MODE!=='required') return failure(404,'not_found');
        if (!env.INSTALL_RATE_LIMITER || !(await env.INSTALL_RATE_LIMITER.limit({key:`verify:${ip}`})).success) return failure(429,'rate_limited');
        const body=await readJson(request); exactKeys(body,['key_id','phone_public_key']);
        if (!key32(body.key_id) || !key32(body.phone_public_key)) return failure(400,'invalid_phone_key');
        return json(unwrap(await env.APP_ADMISSION.getByName('apps').challenge(body.key_id,body.phone_public_key,url.origin)));
      }
      if (url.pathname.startsWith("/v1/pairing/")) {
        const creating = url.pathname === "/v1/pairing/intents" && request.method === "POST";
        const limiter = creating ? env.INSTALL_RATE_LIMITER : env.REQUEST_RATE_LIMITER;
        if (!limiter || !(await limiter.limit({ key: `setup:${ip}` })).success) return failure(429, "rate_limited");
        if (url.pathname === "/v1/pairing/key" && request.method === "GET") return json({ public_key: await setupPublicKey(env), app_attest: env.APP_ATTEST_MODE==='required' ? 'required' : 'off' });
        if (creating) {
          const body = await readJson(request, env.APP_ATTEST_MODE==='required' ? 36_864 : 4096);
          exactKeys(body, env.APP_ATTEST_MODE==='required' ? ['phone_public_key','key_id','challenge','proof','assertion'] : ["phone_public_key"]);
          if (!key32(body.phone_public_key)) return failure(400, "invalid_phone_key");
          let attempt: {identity: string; intent_id: string; owner_token: string; issued: number} | undefined;
          if (env.APP_ATTEST_MODE==='required') {
            if (!key32(body.key_id) || !key32(body.challenge) || typeof body.proof!=='string' || body.proof.length>32_768 || typeof body.assertion!=='boolean') return failure(400,'invalid_verification');
            attempt=unwrap(await env.APP_ADMISSION.getByName('apps').verify(body.key_id,body.phone_public_key,url.origin,body.challenge,body.proof,body.assertion));
            if (!await env.ADMISSION.getByName('service').reserveSetup(attempt.intent_id,attempt.identity,(attempt.issued+1200)*1000)) return failure(429,'setup_capacity_reached');
          } else if (!await env.ADMISSION.getByName("service").setup(true)) return failure(429, "setup_capacity_reached");
          const { ticket, intent } = await issueTicket(env, body.phone_public_key, url.origin, attempt);
          const owner = attempt?.owner_token ?? newToken();
          await env.SETUP_INTENTS.getByName(intent.intent_id).initialize(intent, await tokenHash(owner));
          return json({ ticket, prompt: setupPrompt(ticket), owner_token: owner, ...intent }, 201);
        }
        const match = /^\/v1\/pairing\/([A-Za-z0-9_-]{43})(?:\/(push|complete|cancel)|\/claims(?:\/([0-9a-f-]{36})(?:\/(key|reveal|confirm|enrollment))?)?)?$/.exec(url.pathname);
        const raw = bearer(request);
        if (!match || !raw) return failure(401, "unauthorized");
        // Verify the signed admission ticket before allocating/routing to an object name.
        const intent = await verifyTicket(env, request.headers.get("X-Hermes-Setup") ?? "", url.origin);
        if (intent.intent_id !== match[1]) return failure(401, "wrong_setup");
        const stub = env.SETUP_INTENTS.getByName(intent.intent_id);
        const hash = await tokenHash(raw);
        const body = ["POST", "PUT"].includes(request.method) ? await readJson(request) : {};
        if (url.pathname.endsWith("/claims") && request.method === "POST") {
          if (typeof body.installation_id !== "string" || !UUID_PATTERN.test(body.installation_id) || !key32(body.claim_token)) return failure(400, "invalid_claim");
          if (!await env.ADMISSION.getByName("service").registered(body.installation_id)
            || !await env.INSTALLATIONS.getByName(body.installation_id).authorizeSetup(hash)) return failure(401, "host_required");
          return stub.dispatch("claim", await tokenHash(body.claim_token), body);
        }
        if (request.method === "GET" && !match[2] && !match[4] && !url.pathname.endsWith("/claims")) return stub.dispatch("snapshot", hash, {}, match[3]);
        if (request.method === "PUT" && match[4]) return stub.dispatch(match[4], hash, body, match[3]);
        if (request.method === "PUT" && match[2] === "push") return stub.dispatch("push", hash, body);
        if (request.method === "POST" && ["complete", "cancel"].includes(match[2])) return stub.dispatch(match[2], hash, body);
        return failure(404, "not_found");
      }
      if (url.pathname === "/v1/installations" && request.method === "POST") {
        if (!env.INSTALL_RATE_LIMITER) return failure(503, "rate_limiter_unavailable");
        if (!(await env.INSTALL_RATE_LIMITER.limit({ key: `register:${ip}` })).success) return failure(429, "rate_limited");
        if (env.APP_ATTEST_MODE==='required') {
          const body=await readJson(request);
          if (typeof body.setup_ticket!=='string' || !key32(body.host_token)) return failure(428,'verified_setup_required');
          exactKeys(body,['setup_ticket','host_token']);
          const intent=await verifyTicket(env,body.setup_ticket,url.origin), hash=await tokenHash(body.host_token);
          const id=unwrap(await env.ADMISSION.getByName('service').reserveTicket(intent.intent_id,hash));
          await env.INSTALLATIONS.getByName(id).initialize(id,hash);
          return json({installation_id:id,host_token:body.host_token},201);
        }
        exactKeys(await readJson(request), []);
        const id = crypto.randomUUID();
        const token = newToken();
        if (!await env.ADMISSION.getByName("service").reserve(id)) return failure(503, "registration_capacity_reached");
        try { await env.INSTALLATIONS.getByName(id).initialize(id, await tokenHash(token)); }
        catch (error) { await env.ADMISSION.getByName("service").remove(id); throw error; }
        return json({ installation_id: id, host_token: token }, 201);
      }
      const match = /^\/v1\/installations\/([^/]+)(?:\/.*)?$/.exec(url.pathname);
      if (!match || !UUID_PATTERN.test(match[1])) return failure(404, "not_found");
      if (!bearer(request)) return failure(401, "unauthorized");
      if (!env.REQUEST_RATE_LIMITER) return failure(503, "rate_limiter_unavailable");
      if (!(await env.REQUEST_RATE_LIMITER.limit({ key: `request:${ip}` })).success) return failure(429, "rate_limited");
      if (!await env.ADMISSION.getByName("service").registered(match[1])) return failure(404, "installation_unavailable");
      return env.INSTALLATIONS.getByName(match[1]).fetch(request);
    });
  },
} satisfies ExportedHandler<Env>;
