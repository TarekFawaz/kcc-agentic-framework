import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { report } from "../src/commands/report";
import { applyPayload } from "../src/lock";
import { runTool } from "../src/platform";

// kcc report: the numbers come from the dashboard's own stage-timing functions and the verdict names the slow stages.
setDefaultTimeout(120000);
const root = mkdtempSync(join(tmpdir(), "kcc-report-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const T0 = Date.parse("2026-10-16T08:00:00Z");
const at = (min: number): string => new Date(T0 + min * 60000).toISOString().replace(".000Z", "Z");
let n = 0;
const ev = (min: number, kind: string, extra: Record<string, unknown> = {}, spec: string | null = null, payload: Record<string, unknown> = {}): string =>
  JSON.stringify({ ts: at(min), id: `BC-${String(++n).padStart(5, "0")}`, from: "orchestrator", to: "broadcast", kind, spec, session: null, payload, ...extra });

function capture(fn: () => number): { code: number; out: string } {
  const lines: string[] = [];
  const log = console.log;
  console.log = (...a: unknown[]) => { lines.push(a.join(" ")); };
  try { return { code: fn(), out: lines.join("\n") }; } finally { console.log = log; }
}

function setup(events: string[], src: boolean): void {
  applyPayload(root);
  mkdirSync(join(root, "coordination", "run"), { recursive: true });
  writeFileSync(join(root, "coordination", "run", "run.json"), JSON.stringify({ scenario: "S1", fasttrack: "1", depthlevel: "2", idea: "IDEA-001", status: "done", created: at(0), updated: at(100) }));
  writeFileSync(join(root, "coordination", "backchannel.jsonl"), events.join("\n") + "\n");
  if (src) { mkdirSync(join(root, "src", "IDEA-001-x"), { recursive: true }); writeFileSync(join(root, "src", "IDEA-001-x", "a.ts"), "export {};\n"); }
}

describe("kcc report", () => {
  test("a run inside both budgets passes, with the human wait and stages in the table", () => {
    n = 0;
    setup([
      ev(0, "auto-policy-parsed", {}, null, { flags: ["--fasttrack"] }),
      ev(1, "human-gate-triggered", {}, null, { gate_id: "GATE-001", state: 5 }),
      ev(6, "human-gate-decision", {}, null, { gate_id: "GATE-001", state: 5, decision: "ok" }),
      ev(12, "idea-interrogation-completed"),
      ev(30, "implement-completed", {}, "SPEC-001"),
      ev(90, "session-closed"),
    ], true);
    const r = capture(() => report(["--dir", root]));
    expect(r.code).toBe(0);
    expect(r.out).toContain("## Verdict: PASS");
    expect(r.out).toMatch(/waiting on the human 00:05:00 across 1 gate/);
    expect(r.out).toMatch(/Walking skeleton.*PASS \(00:30:00 of 45 min\)/);
    expect(r.out).toMatch(/Whole app.*PASS \(01:30:00 of 180 min\)/);
  });

  test("a missed budget fails, names the slow stage, and the report goes to --out", () => {
    n = 0;
    setup([
      ev(0, "auto-policy-parsed"),
      ev(75, "idea-interrogation-completed"),
      ev(80, "implement-completed", {}, "SPEC-001"),
      ev(100, "session-closed"),
    ], true);
    const out = join(root, "diagnosis", "ROUND-x.md");
    const r = capture(() => report(["--dir", root, "--out", out]));
    expect(r.code).toBe(1);
    expect(r.out).toContain("FAIL");
    const text = require("node:fs").readFileSync(out, "utf8") as string;
    expect(text).toContain("Walking skeleton (first spec built) | FAIL (01:20:00 of 45 min)");
    expect(text).toMatch(/Slowest stages: .*01:15:00/);
  });

  test("a run that never built code fails even inside the time budget", () => {
    n = 0;
    setup([ev(0, "auto-policy-parsed"), ev(10, "implement-completed", {}, "SPEC-001"), ev(20, "session-closed")], false);
    expect(capture(() => report(["--dir", root, "--no-build"])).code).toBe(1);
  });

  test("the dashboard these events feed still builds", () => {
    n = 0;
    setup([ev(0, "auto-policy-parsed"), ev(5, "implement-completed", {}, "SPEC-001"), ev(9, "session-closed")], true);
    const r = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
    expect(r.status).toBe(0);
  });
});
