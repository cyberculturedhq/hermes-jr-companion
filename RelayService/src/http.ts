import { LIMITS } from "./protocol";

export class HttpError extends Error {
  constructor(readonly status: number, readonly code: string) { super(code); }
}

export function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
}

export function failure(status: number, code: string): Response {
  const response = json({ error: code }, status);
  if (status === 429) response.headers.set("Retry-After", "60");
  return response;
}

/** Read even chunked bodies under a hard cap; never trust Content-Length alone. */
export async function readJson(request: Request): Promise<Record<string, unknown>> {
  if (!request.headers.get("Content-Type")?.toLowerCase().startsWith("application/json")) {
    throw new HttpError(415, "json_required");
  }
  const length = request.headers.get("Content-Length");
  if (length && Number(length) > LIMITS.jsonBytes) throw new HttpError(413, "body_too_large");
  const reader = request.body?.getReader();
  if (!reader) throw new HttpError(400, "invalid_json");
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > LIMITS.jsonBytes) {
        await reader.cancel();
        throw new HttpError(413, "body_too_large");
      }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  try {
    const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value as Record<string, unknown>;
  } catch { throw new HttpError(400, "invalid_json"); }
}

export function exactKeys(value: Record<string, unknown>, keys: string[]): void {
  if (Object.keys(value).length !== keys.length || keys.some((key) => !(key in value))) {
    throw new HttpError(400, "invalid_fields");
  }
}

export async function handleErrors(callback: () => Promise<Response>): Promise<Response> {
  try { return await callback(); }
  catch (error) {
    if (error instanceof HttpError) return failure(error.status, error.code);
    // Never log request URLs, tokens, push references, ciphertext, or raw exceptions.
    return failure(500, "internal_error");
  }
}
