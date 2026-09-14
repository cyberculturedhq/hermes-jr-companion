import { pushAvailable } from "./apns";
import { exactKeys, failure, handleErrors, json, readJson } from "./http";
import { bearer, LIMITS, newToken, PROTOCOL_VERSION, tokenHash, UUID_PATTERN } from "./protocol";
export { InstallationRelay } from "./installation";
export { APNsProviderToken } from "./apns";

export default {
  async fetch(request, env): Promise<Response> {
    return handleErrors(async () => {
      const url = new URL(request.url);
      if (url.protocol !== "https:" && !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) return failure(400, "https_required");
      // No credential-bearing URLs, user-chosen forward destinations, or browser cross-origin access.
      if (url.search || request.headers.has("Origin")) return failure(400, "unsupported_request");
      if (url.pathname === "/v1/capabilities" && request.method === "GET") {
        return json({ protocol_version: PROTOCOL_VERSION, push: pushAvailable(env), max_ciphertext_bytes: LIMITS.ciphertextBytes });
      }
      if (url.pathname === "/health" && request.method === "GET") return json({ status: "ok" });
      // CF-Connecting-IP is set by Cloudflare at ingress; a shared fallback deliberately fails
      // closed for unidentified callers, and makes localhost limits real instead of bypassed.
      const ip = request.headers.get("CF-Connecting-IP") ?? "unidentified";
      if (url.pathname === "/v1/installations" && request.method === "POST") {
        if (!env.INSTALL_RATE_LIMITER) return failure(503, "rate_limiter_unavailable");
        if (!(await env.INSTALL_RATE_LIMITER.limit({ key: `register:${ip}` })).success) return failure(429, "rate_limited");
        exactKeys(await readJson(request), []);
        const id = crypto.randomUUID();
        const token = newToken();
        await env.INSTALLATIONS.getByName(id).initialize(id, await tokenHash(token));
        return json({ installation_id: id, host_token: token }, 201);
      }
      const match = /^\/v1\/installations\/([^/]+)(?:\/.*)?$/.exec(url.pathname);
      if (!match || !UUID_PATTERN.test(match[1])) return failure(404, "not_found");
      if (!bearer(request)) return failure(401, "unauthorized");
      if (!env.REQUEST_RATE_LIMITER) return failure(503, "rate_limiter_unavailable");
      if (!(await env.REQUEST_RATE_LIMITER.limit({ key: `request:${ip}` })).success) return failure(429, "rate_limited");
      return env.INSTALLATIONS.getByName(match[1]).fetch(request);
    });
  },
} satisfies ExportedHandler<Env>;
