import { defineConfig } from "vitest/config";

/**
 * Vitest configuration for the autobuild discovery canvas (Plan 06).
 *
 * Unit tests run on the Node environment by default so the typed
 * control-plane client (``src/api/client.ts``) is exercised against the
 * real ``fetch``/``Response`` globals; component tests added by later
 * Plan 06 tasks opt into a DOM environment per file when needed.
 */
export default defineConfig({
  test: {
    environment: "node",
    include: ["src/**/*.test.{ts,tsx}"],
  },
});
