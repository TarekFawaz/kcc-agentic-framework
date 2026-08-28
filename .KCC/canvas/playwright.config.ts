import { defineConfig } from "@playwright/test";

/**
 * Playwright configuration for the autobuild discovery canvas (Plan 06).
 *
 * The deterministic H2 -> LOCK -> PAUSE -> RESUME E2E (P06-T05) lives
 * under ``e2e/``; this task only scaffolds the runner and its config.
 */
export default defineConfig({
  testDir: "./e2e",
  fullyParallel: false,
  reporter: [["list"]],
  use: {
    trace: "retain-on-failure",
  },
});
