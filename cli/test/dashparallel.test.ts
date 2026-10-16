import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { applyPayload } from "../src/lock";
import { payloadFiles } from "../src/payload";
import { runTool } from "../src/platform";
import { renderHeadless } from "../src/commands/dashboard";

// Parallel agents and the lifecycle flowchart: the builders must emit what the page needs (dispatch agent/model/effort,
// lane run state, lane events, loop-back edges), and the page's pure functions must turn it into concurrency and edge counts.
setDefaultTimeout(180000);
const root = mkdtempSync(join(tmpdir(), "kcc-dashpar-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const T = (hms: string): string => `2026-10-16T${hms}Z`;
const ms = (hms: string): number => Date.parse(T(hms));
let n = 0;
const ev = (hms: string, kind: string, spec: string | null, payload: Record<string, unknown> = {}, from = "kcc-run") =>
  JSON.stringify({ ts: T(hms), id: `BC-${String(++n).padStart(5, "0")}`, from, to: "broadcast", kind, spec, session: null, payload });
const done = (hms: string, kind: string, spec: string, state: number, name: string, extra: Record<string, unknown> = {}) =>
  ev(hms, kind, spec, { state, state_name: name, wave: "", attempt: 0, skipped: false, source: "kcc-run", ...extra });
const sel = (hms: string, spec: string, agent: string, item: string, model: string, effort: string, tier: string) =>
  ev(hms, "model-selected", spec, { agent, item, tier, model, effort, reasons: "default", mode: "direct", source: "kcc-route" });

function put(rel: string, text: string): void {
  const p = join(root, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, text);
}
function logFile(lane: string, name: string, start: string, end: string, agent: string, model: string, effort: string, label: string): void {
  const rel = `.kcc-lanes/${lane}/coordination/run/logs/${name}`;
  put(rel, `# kcc-run ${T(start)} harness claude\n# claude -p --agent ${agent} --model ${model} --effort ${effort} --permission-mode auto "${label}"\n`);
  const t = ms(end) / 1000;
  utimesSync(join(root, rel), t, t);
}

let D: any;
let html = "";
let fns: any;

beforeAll(() => {
  applyPayload(root);
  // run-wide: the main backchannel only has the early states; the lanes' own events carry the rest
  const main = [
    ev("10:00:00", "auto-policy-parsed", null, { scenario: "S2", fasttrack: true, parallel: true, source: "kcc-run" }),
    done("10:03:00", "idea-interrogation-completed", "IDEA-001-demo", 1, "IDEA"),
    done("10:20:00", "spec-created", "IDEA-001-demo", 9, "SPECS"),
  ];
  put("coordination/backchannel.jsonl", main.join("\n") + "\n");
  put("coordination/run/run.json", JSON.stringify({ status: "stopped", reason: "until 9", state: "9", scenario: "S2", fasttrack: "1", parallel: "1", idea: "IDEA-001-demo", specs: "IDEA-001-demo/SPEC-001-a IDEA-001-demo/SPEC-002-b", spec_index: "0" }));
  // SPEC-001: implement waves 1+2, then TEST fails -> FIX -> TEST again (the loop), running at TEST attempt 2
  const l1 = [
    ...main,
    done("10:27:02", "toolchain-preflight-result", "SPEC-001", 14, "PREFLIGHT", { skipped: true }),
    sel("10:27:05", "SPEC-001", "implementer", "wave 1", "claude-sonnet-5-5", "high", "balanced"),
    done("10:40:00", "implement-completed", "SPEC-001", 15, "IMPLEMENT", { wave: "1" }),
    sel("10:40:03", "SPEC-001", "implementer", "wave 2", "claude-sonnet-5-5", "high", "balanced"),
    done("10:52:00", "implement-completed", "SPEC-001", 15, "IMPLEMENT", { wave: "2" }),
    done("10:52:02", "fix-completed", "SPEC-001", 19, "FIX", { skipped: true }),
    sel("10:52:05", "SPEC-001", "verifier", "spec", "claude-opus-5-5", "xhigh", "strong"),
    sel("11:00:05", "SPEC-001", "implementer", "spec", "claude-sonnet-5-5", "high", "balanced"),
    done("11:05:00", "fix-completed", "SPEC-001", 19, "FIX"),
    sel("11:05:05", "SPEC-001", "verifier", "spec", "claude-opus-5-5", "xhigh", "strong"),
  ];
  put(".kcc-lanes/SPEC-001/coordination/backchannel.jsonl", l1.join("\n") + "\n");
  put(".kcc-lanes/SPEC-001/coordination/run/run.json", JSON.stringify({ status: "running", state: "16", attempts: "16:SPEC-001=1", updated: T("11:11:50"), fasttrack: "1" }));
  logFile("SPEC-001", "state-15-SPEC-001-w1-1.log", "10:27:05", "10:40:00", "implementer", "claude-sonnet-5-5", "high", "KCC run state 15 IMPLEMENT for SPEC-001 wave 1");
  logFile("SPEC-001", "state-15-SPEC-001-w2-1.log", "10:40:03", "10:52:00", "implementer", "claude-sonnet-5-5", "high", "KCC run state 15 IMPLEMENT for SPEC-001 wave 2");
  logFile("SPEC-001", "state-16-SPEC-001-1.log", "10:52:05", "11:00:00", "verifier", "claude-opus-5-5", "xhigh", "KCC run state 16 TEST for SPEC-001");
  logFile("SPEC-001", "state-19-SPEC-001-1.log", "11:00:05", "11:05:00", "implementer", "claude-sonnet-5-5", "high", "KCC run state 19 FIX for SPEC-001");
  logFile("SPEC-001", "state-16-SPEC-001-2.log", "11:05:05", "11:05:06", "verifier", "claude-opus-5-5", "xhigh", "KCC run state 16 TEST for SPEC-001");
  // SPEC-002: implements at the same time as SPEC-001 (the overlap), then waits on a loop gate
  const l2 = [
    ...main,
    done("10:30:02", "toolchain-preflight-result", "SPEC-002", 14, "PREFLIGHT", { skipped: true }),
    sel("10:30:05", "SPEC-002", "implementer", "wave 1", "claude-sonnet-5-5", "high", "balanced"),
    done("10:45:00", "implement-completed", "SPEC-002", 15, "IMPLEMENT", { wave: "1" }),
    ev("10:58:30", "human-gate-triggered", "SPEC-002", { gate: "loop", gate_id: "GATE-001", kind: "loop", state: 19, state_name: "FIX", reason: "Exit check failed 3 times (CR-3). Revise, escalate, or abort?", allowed_answers: ["revise", "escalate", "abort"], source: "kcc-run" }),
  ];
  put(".kcc-lanes/SPEC-002/coordination/backchannel.jsonl", l2.join("\n") + "\n");
  put(".kcc-lanes/SPEC-002/coordination/run/run.json", JSON.stringify({ status: "paused", reason: "paused at gate GATE-001 (loop) in state 19", state: "19", attempts: "19:SPEC-002=3", updated: T("10:58:30"), gate_id: "GATE-001", gate_name: "loop", gate_state: "19", fasttrack: "1" }));
  logFile("SPEC-002", "state-15-SPEC-002-w1-1.log", "10:30:05", "10:45:00", "implementer", "claude-sonnet-5-5", "high", "KCC run state 15 IMPLEMENT for SPEC-002 wave 1");
  for (const s of ["SPEC-001", "SPEC-002"]) put(`specs/IDEA-001-demo-Specs/${s}-x/${s}-x.md`, `# ${s}: part\n\n| Status | Priority |\n|---|---|\n| In progress | P1 |\n`);

  const r = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
  expect(r.status).toBe(0);
  html = readFileSync(join(root, "dashboard", "index.html"), "utf8");
  D = JSON.parse(/<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/.exec(html)![1]!);

  // the lanes' file times are the real clock of this test run; pin them so the page model is deterministic
  for (const l of D.lanes) l.updated = T("11:11:50");

  const tpl = payloadFiles().get("kernel/templates/dashboard.html")!.toString("utf8");
  const stage = tpl.split("/*stage-timing:start*/")[1]!.split("/*stage-timing:end*/")[0]!;
  const block = tpl.split("/*parallel-view:start*/")[1]!.split("/*parallel-view:end*/")[0]!;
  const stubs = `function esc(s){return (s==null?'':String(s)).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
    function fmtDur(ms){return Math.round((Number(ms)||0)/1000)+'s';}
    function modelShort(m){return String(m||'').replace(/^claude-/,'');}
    function approved(s){return false;}`;
  fns = new Function(`${stubs}\n${stage}\n${block}\nreturn { buildRuns, markOpen, flowScopes, stageStats, concurrencySegments, flowSVG, timelineSVG, transitionRows };`)();
});

describe("builders emit what the parallel view needs", () => {
  test("state table carries the loop-back edges and the attempt limit", () => {
    const byName = Object.fromEntries(D.states.map((s: any) => [s.name, s]));
    expect(byName.TEST.goto).toBe(byName.FIX.id);
    expect(byName.REVIEW.goto).toBe(byName.FIX.id);
    expect(byName.IMPLEMENT.goto).toBeNull();
    expect(D.maxAttempts).toBe(3);
  });

  test("dispatch logs of every lane carry agent, model and effort and overlap in time", () => {
    const logs = D.runLogs.filter((l: any) => l.state === 15);
    expect(logs.length).toBe(3);
    for (const l of logs) {
      expect(l.agent).toBe("implementer");
      expect(l.model).toBe("claude-sonnet-5-5");
      expect(l.effort).toBe("high");
    }
    const a = D.runLogs.find((l: any) => l.spec === "SPEC-001" && l.wave === "1");
    const b = D.runLogs.find((l: any) => l.spec === "SPEC-002" && l.wave === "1");
    expect(Date.parse(b.started)).toBeLessThan(Date.parse(a.ended)); // the two lanes ran side by side
    expect(Date.parse(a.started)).toBeLessThan(Date.parse(b.ended));
  });

  test("lanes report their own run state, attempts and open gate; lane events the workspace lacks are listed", () => {
    const l1 = D.lanes.find((l: any) => l.spec === "SPEC-001");
    const l2 = D.lanes.find((l: any) => l.spec === "SPEC-002");
    expect(l1.runStatus).toBe("running");
    expect(l1.runAttempts).toBe("16:SPEC-001=1");
    expect(l2.runStatus).toBe("paused");
    expect(l2.runGateId).toBe("GATE-001");
    expect(l2.runReason).toContain("GATE-001");
    expect(D.laneEvents.length).toBeGreaterThan(5);
    expect(D.laneEvents.every((e: any) => e.lane.startsWith("SPEC-"))).toBe(true);
    expect(D.laneEvents.some((e: any) => e.kind === "human-gate-triggered" && e.lane === "SPEC-002")).toBe(true);
    // events the main backchannel already holds are not repeated
    expect(D.laneEvents.some((e: any) => e.kind === "spec-created")).toBe(false);
  });
});

describe("the page's model of parallel runs and loops", () => {
  const now = ms("11:12:00");
  const model = () => {
    const rb = fns.markOpen(D, fns.buildRuns(D, now), now);
    return { rb, F: fns.flowScopes(D, rb, now), stats: fns.stageStats(rb, now) };
  };
  const id = (name: string) => D.states.find((s: any) => s.name === name).id;

  test("two lanes implementing at the same time give peak parallel 2 and a speed-up above 1", () => {
    const { stats } = model();
    const s = stats[id("IMPLEMENT")];
    expect(s.runs).toBe(3);
    expect(s.peak).toBe(2);
    expect(s.sum).toBeGreaterThan(s.wall);
    expect(s.speedup).toBeGreaterThan(1.2);
  });

  test("a failed test that went to FIX and back is a counted loop on the spec's flowchart, and the current state is marked", () => {
    const { F } = model();
    const sp = F.specs.find((x: any) => x.id === "SPEC-001");
    const T = id("TEST"), X = id("FIX");
    expect(sp.E[`${T}>${X}`]).toBe(1); // TEST failed once -> FIX
    expect(sp.E[`${X}>${T}`]).toBeGreaterThanOrEqual(1); // FIX -> TEST again
    expect(sp.E[`${id("IMPLEMENT")}>${id("IMPLEMENT")}:wave`]).toBe(1); // wave 1 -> wave 2
    expect(sp.cur).toBe(T);
    expect(sp.status).toBe("running");
    expect(sp.live).toBe(true);
    expect(sp.att).toBe(1);
  });

  test("an open gate lights the spec, not its neighbour", () => {
    const { F, rb } = model();
    const sp2 = F.specs.find((x: any) => x.id === "SPEC-002");
    expect(sp2.status).toBe("paused");
    expect(sp2.cur).toBe(id("FIX"));
    expect(sp2.live).toBe(false);
    expect(rb.gates.filter((g: any) => g.open).map((g: any) => g.id)).toEqual(["GATE-001"]);
    expect(F.specs.find((x: any) => x.id === "SPEC-001").ctx.openGate).toBeNull();
  });

  test("a run nobody wrote to for a long time is stale, not running", () => {
    const later = ms("12:30:00");
    const rb = fns.markOpen(D, fns.buildRuns(D, later), later);
    const F = fns.flowScopes(D, rb, later);
    const sp = F.specs.find((x: any) => x.id === "SPEC-001");
    expect(sp.stale).toBe(true);
    expect(sp.live).toBe(false);
    expect(rb.runs.filter((r: any) => r.open).length).toBe(0);
    expect(rb.runs.filter((r: any) => r.stale).length).toBeGreaterThan(0);
  });

  test("with no events, logs or transcripts there is nothing to draw as taken", () => {
    const empty = { states: D.states, run: null, lanes: [], runLogs: [], agents: [], events: [], laneEvents: [], specs: [], maxAttempts: 3 };
    const rb = fns.markOpen(empty, fns.buildRuns(empty, now), now);
    const F = fns.flowScopes(empty, rb, now);
    expect(rb.runs.length).toBe(0);
    expect(Object.keys(F.shared.E).length).toBe(0);
    expect(F.specs.length).toBe(0);
  });

  test("the SVG and the timeline render, with a text table of the same transitions", () => {
    const { F, rb } = model();
    const sp = F.specs[0];
    const svg = fns.flowSVG({ nodes: sp.nodes, E: sp.E, N: sp.N, gates: sp.gates, cur: sp.cur, prev: sp.prev, live: sp.live, status: sp.status, att: sp.att, entry: 1 }, { label: "x" });
    expect(svg.startsWith("<svg")).toBe(true);
    expect(svg).toContain("tabindex=\"0\"");
    expect(svg).toContain("&times;1");
    expect(fns.transitionRows(sp, rb.M).length).toBeGreaterThan(3);
    const tl = fns.timelineSVG(rb, now, 0);
    expect(tl.peak).toBe(2);
    expect(tl.svg).toContain("agents at the same time");
    expect(tl.rows.some((r: any) => r.gate && r.gate.open)).toBe(true);
  });
});

describe("rendered page", () => {
  test("shows the Now strip, the timeline and one flowchart per spec (skipped when no browser is installed)", () => {
    const file = join(root, "dashboard", "index.html");
    const dom = renderHeadless(file);
    if (dom === undefined) return;
    expect(dom).toContain("id=\"nowcard\"");
    expect(dom).toContain("Parallel timeline");
    expect(dom).toContain("Lifecycle flowchart");
    expect((dom.match(/class="flow"/g) ?? []).length).toBeGreaterThanOrEqual(3); // shared + 2 specs
  });
});
