import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startDashboardServer } from "../src/commands/dashboard";
import { applyPayload } from "../src/lock";
import { payloadFiles } from "../src/payload";

// A page that is rebuilt when it is requested cannot go stale: rounds 8 and 9 froze whenever the process that
// regenerated the file (a hook, the lane scheduler) was not running.
setDefaultTimeout(120000);
const root = mkdtempSync(join(tmpdir(), "kcc-serve-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const ev = (id: number, kind: string): string => JSON.stringify({ ts: "2026-10-16T08:00:00Z", id: `BC-${String(id).padStart(5, "0")}`, from: "orchestrator", to: "broadcast", kind, spec: null, session: null, payload: {} });

describe("kcc dashboard --serve", () => {
  test("every request shows the files as they are now, and only the page, its data and a probe are served", async () => {
    applyPayload(root);
    mkdirSync(join(root, "coordination"), { recursive: true });
    writeFileSync(join(root, "coordination", "backchannel.jsonl"), ev(1, "auto-policy-parsed") + "\n");
    const server = startDashboardServer(root, { port: 0, minAgeMs: 0 });
    expect(server).toBeDefined();
    try {
      const events = async (): Promise<number> => ((await (await fetch(server!.url + "data.json")).json()) as { events: unknown[] }).events.length;
      expect(await events()).toBe(1);
      appendFileSync(join(root, "coordination", "backchannel.jsonl"), ev(2, "idea-interrogation-completed") + "\n");
      expect(await events()).toBe(2); // no regeneration by anything else: the request rebuilt it
      const page = await fetch(server!.url);
      expect(page.status).toBe(200);
      expect(page.headers.get("cache-control")).toBe("no-store");
      expect(await page.text()).toContain('id="kcc-data"');
      expect((await fetch(server!.url + "healthz")).status).toBe(200);
      expect((await fetch(server!.url + "coordination/backchannel.jsonl")).status).toBe(404);
      expect((await fetch(server!.url + ".KCC/settings.json")).status).toBe(404);
    } finally {
      server!.stop();
    }
  });
  test("the page reloads itself over http, notices a dead server, and says so when it is stale as a file", () => {
    const tpl = payloadFiles().get("kernel/templates/dashboard.html")!.toString("utf8");
    expect(tpl).toContain("var served=/^https?:/.test(location.protocol)");
    expect(tpl).toContain("The dashboard server has stopped");
    expect(tpl).toContain("probably not updating");
  });
});
