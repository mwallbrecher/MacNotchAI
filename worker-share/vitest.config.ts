import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

const testSecret = (byte: number): string => Buffer.alloc(32, byte).toString("base64url");
const verifierTestSecret = testSecret(0x31);
const keyWrapTestSecret = testSecret(0x72);

// `secrets.required` validates before Miniflare applies binding overrides. Populate
// this test process only so config validation is quiet and still production-safe.
process.env.VERIFIER_HMAC_SECRET = verifierTestSecret;
process.env.KEY_WRAP_SECRET = keyWrapTestSecret;

export default defineConfig({
  plugins: [
    cloudflareTest(async () => {
      const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
      return {
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          // Deterministic test-only values. Production values exist only as encrypted
          // Cloudflare secret bindings and are never committed.
          bindings: {
            TEST_MIGRATIONS: migrations,
            VERIFIER_HMAC_SECRET: verifierTestSecret,
            KEY_WRAP_SECRET: keyWrapTestSecret,
          },
        },
      };
    }),
  ],
  test: {
    setupFiles: ["./tests/apply-migrations.ts"],
    testTimeout: 20_000,
  },
});
