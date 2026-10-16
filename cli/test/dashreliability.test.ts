import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { applyPayload } from "../src/lock";
import { payloadFiles } from "../src/payload";
import { runTool } from "../src/platform";
import { checkDashboardHtml, renderHeadless } from "../src/commands/dashboard";

// Dashboard reliability: the page must compile, and its stage times must match what the run did.
// Scenarios come from the test rounds: a chat-driven run whose gates name their state ("IDEA") and
// whose human waits were counted as agent time (round 6), parallel specs (round 5), an open gate.
setDefaultTimeout(120000);
const root = mkdtempSync(join(tmpdir(), "kcc-dashrel-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const tpl = payloadFiles().get("kernel/templates/dashboard.html")!.toString("utf8");
const block = tpl.split("/*stage-timing:start*/")[1]!.split("/*stage-timing:end*/")[0]!;
const fns = new Function(`${block}; return { stageTimes, fmtHMS, eventSpans, gateSpans, specStageTimes };`)() as {
  stageTimes: (d: any, now: number) => { rows: any[]; totals: any };
  fmtHMS: (ms: number) => string;
  eventSpans: (d: any, now: number) => any;
  gateSpans: (d: any, now: number) => any[];
  specStageTimes: (d: any, id: string) => Record<string, number>;
};
const { stageTimes, fmtHMS } = fns;

// The fast-track shape of the state table, as the generator marks it.
const STATES = [
  { id: 0, name: "REPO", scope: "run" }, { id: 1, name: "IDEA", scope: "run" }, { id: 2, name: "ROI", scope: "run", skipped: true },
  { id: 3, name: "TECH", scope: "run" }, { id: 4, name: "SPECIALISTS", scope: "run" }, { id: 5, name: "CONFIRM", scope: "run", skipped: true },
  { id: 6, name: "ARCH", scope: "run" }, { id: 7, name: "ARCH-GATE", scope: "run", skipped: true }, { id: 8, name: "BUDGET-0", scope: "run", skipped: true },
  { id: 9, name: "SPECS", scope: "run" }, { id: 10, name: "BUDGET-P", scope: "spec", skipped: true }, { id: 11, name: "PLAN", scope: "spec" },
  { id: 12, name: "WINDOWS", scope: "spec", skipped: true }, { id: 13, name: "BUDGET-I", scope: "spec", skipped: true }, { id: 14, name: "PREFLIGHT", scope: "spec" },
  { id: 15, name: "IMPLEMENT", scope: "wave" }, { id: 16, name: "TEST", scope: "spec" }, { id: 17, name: "REVIEW", scope: "spec" }, { id: 18, name: "CLOSE", scope: "run" },
];
const T = (hhmmss: string): string => `2026-10-15T${hhmmss}Z`;
const ms = (hhmmss: string): number => Date.parse(T(hhmmss));
let n = 0;
const ev = (ts: string, kind: string, from: string, spec: string | null, payload: Record<string, unknown> = {}) => ({ ts: T(ts), id: `BC-${String(++n).padStart(5, "0")}`, from, to: "broadcast", kind, spec, session: null, payload });
const row = (r: { rows: any[] }, name: string) => r.rows.find((x) => x.name === name);

describe("the page compiles", () => {
  test("every script block of the template is valid JavaScript", () => {
    const scripts = [...tpl.matchAll(/<script(?![^>]*application\/json)[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]!);
    expect(scripts.length).toBeGreaterThan(0);
    for (const s of scripts) expect(() => new Function(s)).not.toThrow();
  });
});

describe("chat-driven run (round 6 shape)", () => {
  // REPO gate 21:12:42-21:15:12; IDEA runs 21:15:13-21:54:31 with a 34m22s gate (21:16:35-21:50:57) inside.
  const events = [
    ev("21:12:41", "auto-policy-parsed", "orchestrator", null),
    ev("21:12:42", "human-gate-triggered", "orchestrator", null, { gate_id: "GATE-001", state: "REPO" }),
    ev("21:15:12", "human-gate-decision", "human", null, { gate_id: "GATE-001", state: "REPO", decision: "init-local" }),
    ev("21:15:13", "repo-bootstrap-decision", "orchestrator", null),
    ev("21:16:35", "human-gate-triggered", "orchestrator", null, { gate_id: "GATE-002", state: "IDEA" }),
    ev("21:50:57", "human-gate-decision", "human", null, { gate_id: "GATE-002", state: "IDEA", decision: "confirm" }),
    ev("21:54:31", "idea-interrogation-completed", "idea-interrogator", "IDEA-001"),
  ];
  const d = { states: STATES, run: { status: "running", state: 3 }, runLogs: [], events };

  test("a gate that names its state by name is paired, and its wait is human time, not agent time", () => {
    const r = stageTimes(d, ms("21:56:00"));
    const idea = row(r, "IDEA");
    expect(fmtHMS(idea.humanMs)).toBe("00:34:22");
    // IDEA span 21:12:41 -> 21:54:31 = 41:50, minus the REPO gate (2:30) and the IDEA gate (34:22) = 4:58
    expect(fmtHMS(idea.agentMs)).toBe("00:04:58");
    expect(idea.dominant).toBe("human");
    expect(fmtHMS(r.totals.humanMs)).toBe("00:36:52");
  });

  test("the current stage ticks from the last milestone and waits on an agent", () => {
    const r = stageTimes(d, ms("21:56:00"));
    const tech = row(r, "TECH");
    expect(tech.waiting).toBe("agent");
    expect(fmtHMS(tech.totalMs)).toBe("00:01:29");
  });

  test("an open gate in a chat run shows the stage waiting on the human from the moment it asked", () => {
    const d2 = { ...d, events: [...events, ev("21:55:00", "human-gate-triggered", "orchestrator", null, { gate_id: "GATE-003", state: "TECH" })] };
    const r = stageTimes(d2, ms("22:00:00"));
    const tech = row(r, "TECH");
    expect(tech.waiting).toBe("human");
    expect(fmtHMS(tech.openMs)).toBe("00:05:00");
    expect(fmtHMS(r.totals.humanMs)).toBe("00:41:52"); // 2:30 + 34:22 + 5:00
  });

  test("a decision without a gate id pairs with the oldest open gate", () => {
    const d3 = { states: STATES, run: { status: "running", state: 3 }, runLogs: [], events: [
      ev("10:00:00", "auto-policy-parsed", "orchestrator", null),
      ev("10:01:00", "human-gate-triggered", "orchestrator", null, { state: "IDEA" }),
      ev("10:04:00", "human-gate-decision", "human", null, { decision: "ok" }),
      ev("10:06:00", "idea-interrogation-completed", "idea-interrogator", "IDEA-001"),
    ] };
    const r = stageTimes(d3, ms("10:07:00"));
    expect(fmtHMS(row(r, "IDEA").humanMs)).toBe("00:03:00");
    expect(fmtHMS(row(r, "IDEA").agentMs)).toBe("00:03:00");
  });
});

describe("parallel specs (round 5 shape)", () => {
  const events = [
    ev("19:00:00", "roadmap-created", "spec-writer", "IDEA-001"),
    ev("19:00:00", "spec-created", "spec-writer", "SPEC-001"), ev("19:00:00", "spec-created", "spec-writer", "SPEC-002"), ev("19:00:00", "spec-created", "spec-writer", "SPEC-003"),
    ev("19:10:00", "plan-created", "planner", "SPEC-001"), ev("19:12:00", "plan-created", "planner", "SPEC-002"), ev("19:14:00", "plan-created", "planner", "SPEC-003"),
  ];
  const d = { states: STATES, run: { status: "running", state: 14 }, runLogs: [], events };
  test("three plans written side by side count once as wall-clock time, with three attempts", () => {
    const r = stageTimes(d, ms("19:15:00"));
    const plan = row(r, "PLAN");
    expect(fmtHMS(plan.agentMs)).toBe("00:14:00"); // 19:00 -> 19:14, not 10+12+14
    expect(plan.attempts).toBe(3);
  });
  test("each spec keeps its own plan time", () => {
    expect(fmtHMS(fns.specStageTimes(d, "SPEC-002")[11]!)).toBe("00:12:00");
    expect(fmtHMS(fns.specStageTimes(d, "SPEC-003")[11]!)).toBe("00:14:00");
  });
  test("a gate during planning is human time for PLAN, not agent time", () => {
    const d2 = { ...d, events: [...events.slice(0, 4), ev("19:02:00", "human-gate-triggered", "orchestrator", "SPEC-001", { gate_id: "G", state: "PLAN" }), ev("19:05:00", "human-gate-decision", "human", "SPEC-001", { gate_id: "G" }), ...events.slice(4)] };
    const r = stageTimes(d2, ms("19:15:00"));
    expect(fmtHMS(row(r, "PLAN").humanMs)).toBe("00:03:00");
    expect(fmtHMS(row(r, "PLAN").agentMs)).toBe("00:11:00");
  });
});

describe("generator to page, end to end", () => {
  test("a chat run's gates and stage come out of the generated page with the right numbers", () => {
    applyPayload(root);
    const put = (rel: string, text: string) => { mkdirSync(dirname(join(root, rel)), { recursive: true }); writeFileSync(join(root, rel), text); };
    put("coordination/run/run.json", JSON.stringify({ scenario: "S2", fasttrack: "1", idea: "IDEA-001" }));
    const events = [
      ev("21:12:41", "auto-policy-parsed", "orchestrator", null),
      ev("21:16:35", "human-gate-triggered", "orchestrator", null, { gate_id: "GATE-002", state: "IDEA" }),
      ev("21:50:57", "human-gate-decision", "human", null, { gate_id: "GATE-002", state: "IDEA", decision: "confirm" }),
      ev("21:54:31", "idea-interrogation-completed", "idea-interrogator", "IDEA-001"),
    ];
    put("coordination/backchannel.jsonl", events.map((e) => JSON.stringify(e)).join(String.fromCharCode(10)) + String.fromCharCode(10));
    const r = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
    expect(r.status).toBe(0);
    const html = readFileSync(join(root, "dashboard", "index.html"), "utf8");
    const data = JSON.parse(html.match(/<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/)![1]!);
    // the page parses string payloads at load; do the same
    data.events.forEach((e: any) => { if (typeof e.payload === "string" && /^[\[{]/.test(e.payload)) { try { e.payload = JSON.parse(e.payload); } catch { /* keep */ } } });
    expect(data.run.state).toBe(4); // a fast-track run: IDEA done -> BRIEFS (the fast-track table has no ROI or TECH)
    const st = stageTimes(data, ms("21:56:00"));
    expect(fmtHMS(row(st, "IDEA").humanMs)).toBe("00:34:22");
    expect(fmtHMS(row(st, "IDEA").agentMs)).toBe("00:07:28");
    expect(data.run.status).toBe("idle"); // nothing happened for 30 minutes: no timer keeps running
    expect(row(st, "BRIEFS").waiting).toBe(""); // fast-track table: BRIEFS follows IDEA, and an idle run waits on nobody
  });
});

describe("kcc dashboard --check", () => {
  test("the generated page passes the compile and data checks, and a broken template is caught", () => {
    const html = readFileSync(join(root, "dashboard", "index.html"), "utf8");
    expect(checkDashboardHtml(html).ok).toBe(true);
    // an apostrophe inside a single-quoted string: the exact defect that shipped a blank page once
    const broken = html.replace("function fmtHMS(ms){", "var oops='it's broken';function fmtHMS(ms){");
    const c = checkDashboardHtml(broken);
    expect(c.ok).toBe(false);
    expect(c.problems.join(" ")).toContain("does not compile");
  });
  test("rendered headless (when a browser is available), the view is not blank", () => {
    const dom = renderHeadless(join(root, "dashboard", "index.html"));
    if (dom === undefined) return; // no Chrome/Edge on this machine: the compile check above still ran
    expect(/id="view"[^>]*>\s*<(div|p)/.test(dom)).toBe(true);
    expect(dom).toContain("Lifecycle pipeline");
  });
});

describe("a chat run with no run.json", () => {
  test("fast track is read from the auto-policy-parsed event, and the fast-track table is shown", () => {
    const put = (rel: string, text: string) => { mkdirSync(dirname(join(root, rel)), { recursive: true }); writeFileSync(join(root, rel), text); };
    rmSync(join(root, "coordination", "run"), { recursive: true, force: true });
    put("coordination/backchannel.jsonl", JSON.stringify({ ts: T("21:12:41"), id: "BC-00001", from: "orchestrator", to: "human", kind: "auto-policy-parsed", spec: null, session: null, payload: { scenario: "S1", flags: ["--fasttrack"] } }) + String.fromCharCode(10));
    expect(runTool(root, "build-dashboard", ["--repo-root", root], { capture: true }).status).toBe(0);
    const html = readFileSync(join(root, "dashboard", "index.html"), "utf8");
    const data = JSON.parse(html.match(/<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/)![1]!);
    expect(data.run.fasttrack).toBe(true);
    expect(data.states.map((s: any) => s.id)).toEqual([0, 1, 4, 5, 6, 9, 14, 15, 16, 17, 18]);
  });
});

