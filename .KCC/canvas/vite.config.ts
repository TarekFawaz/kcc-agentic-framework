import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

/**
 * Vite configuration for the autobuild discovery canvas (Plan 06).
 *
 * The canvas talks to the control-plane discovery API, which the E2E
 * harness (P06-T05) serves through the dev-server proxy; no proxy is
 * configured here on purpose — the typed client is pointed at the
 * control-plane base URL explicitly by the caller / E2E helper.
 */
export default defineConfig({
  plugins: [react()],
});
