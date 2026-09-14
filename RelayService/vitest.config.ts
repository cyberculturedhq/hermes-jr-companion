import { generateKeyPairSync } from "node:crypto";
import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Ephemeral local test key. This is never an Apple credential or written to disk.
const setupKey = generateKeyPairSync("ed25519").privateKey.export({ type: "pkcs8", format: "der" }).toString("base64url");
const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    miniflare: {
      bindings: {
        SETUP_TICKET_PRIVATE_KEY: setupKey,
        APNS_TEAM_ID: "TESTTEAM01",
        APNS_KEY_ID: "TESTKEY001",
        APNS_TOPIC: "test.hermes.jr",
        APNS_PRIVATE_KEY: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
      },
    },
  })],
  test: { include: ["test/**/*.test.ts"], testTimeout: 10_000, hookTimeout: 10_000 },
});
