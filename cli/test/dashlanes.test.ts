import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { applyPayload } from "../src/lock";
import { payloadFiles } from "../src/payload";
import { runTool } from "../src/platform";
import { renderHeadless } from "../src/commands/dashboard";
import { buildReport, readLaneEvents, report } from "../src/commands/report";

// Round 11 (test round): WRITE and PLAN ran in lanes, TEST ran three times under one log name, the router's reasons were on no page,
// a review ended QUALITY_DEFERRED, a silent run decided gates by policy. This fixture has two lanes (their own backchannels, which also
// hold a copy of the run-wide events), a PLAN retry, a TEST that ran twice (the second run overwrote the first one's log), a loop through
// FIX, a human gate (30 min) and a gate the policy answered, and asserts what the stage table, the report and the page's new cards say.
setDefaultTimeout(180000);
const root = mkdtempSync(join(tmpdir(), "kcc-dashlanes-"));
afterAll(() => { if (!process.env.KCC_TEST_KEEP) rmSync(root, { recursive: true, force: true }); });

const T = (hms: string): string => `2026-10-16T${hms}Z`;
const ms = (hms: string): number => Date.parse(T(hms));
let n = 0;
const ev = (hms: string, kind: string, spec: string | null, payload: Record<string, unknown> = {}, from = "kcc-run") =>
  JSON.stringify({ ts: T(hms), id: `BC-${String(++n).padStart(5, "0")}`, from, to: "broadcast", kind, spec, session: null, payload });
const start = (hms: string, spec: string | null, state: number, name: string, agent: string, model: string, effort: string, extra: Record<string, unknown> = {}) =>
  ev(hms, "agent-run-started", spec, { state, state_name: name, agent, model, effort, attempt: 1, wave: "", log: `coordination/run/logs/state-${state}-${spec ?? "run"}-1.log`, started: T(hms), source: "kcc-run", ...extra });
const end = (hms: string, spec: string | null, state: number, name: string, agent: string, seconds: number, extra: Record<string, unknown> = {}) =>
  ev(hms, "agent-run-ended", spec, { state, state_name: name, agent, attempt: 1, wave: "", exit: 0, seconds, ended: T(hms), source: "kcc-run", ...extra });
const sel = (hms: string, spec: string, agent: string, item: string, tier: string, model: string, effort: string, reasons: unknown, pass = "") =>
  ev(hms, "model-selected", spec, { agent, item, tier, model, effort, reasons, mode: "direct", pass, source: "kcc-route" });
const done = (hms: string, kind: string, spec: string, state: number, name: string, extra: Record<string, unknown> = {}) =>
  ev(hms, kind, spec, { state, state_name: name, wave: "", attempt: 0, skipped: false, source: "kcc-run", ...extra });

function put(rel: string, text: string): void {
  const p = join(root, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, text);
}
function logFile(lane: string, name: string, startHms: string, endHms: string, agent: string, model: string, effort: string): void {
  const rel = `.kcc-lanes/${lane}/coordination/run/logs/${name}`;
  put(rel, `# kcc-run ${T(startHms)} harness claude\n# claude -p --agent ${agent} --model ${model} --effort ${effort} --permission-mode auto "x"\n`);
  const t = ms(endHms) / 1000;
  utimesSync(join(root, rel), t, t);
}

const HAIKU = "claude-haiku-5-5", SONNET = "claude-sonnet-5-5";
let D: any;
let html = "";
let fns: any;

beforeAll(() => {
  applyPayload(root);
  const main = [
    ev("10:00:00", "auto-policy-parsed", null, { scenario: "S2", fasttrack: true, source: "kcc-run" }),
    start("10:00:01", null, 1, "IDEA", "idea-interrogator", SONNET, "high"), end("10:02:00", null, 1, "IDEA", "idea-interrogator", 119),
    start("10:02:01", null, 6, "ARCH", "architect", SONNET, "high"), end("10:07:00", null, 6, "ARCH", "architect", 299),
    start("10:07:01", null, 9, "SPECS", "spec-writer", SONNET, "high"), end("10:08:00", null, 9, "SPECS", "spec-writer", 59),
  ];
  // the workspace file only has the run-wide start; each lane's own backchannel has a copy of it plus what the lane did
  put("coordination/backchannel.jsonl", main.join("\n") + "\n");
  put("coordination/run/run.json", JSON.stringify({ status: "stopped", reason: "specs need attention: SPEC-002", state: "9", scenario: "S2", fasttrack: "1", created: T("10:00:00"), updated: T("11:20:11"), idea: "IDEA-001-demo", specs: "IDEA-001-demo/SPEC-001-a IDEA-001-demo/SPEC-002-b", spec_index: "0" }));

  const l1 = [
    ...main,
    // WRITE: haiku, router reasons in the old shape (a model-selected event before the start)
    sel("10:09:00", "SPEC-001", "spec-writer", "spec", "fast", HAIKU, "high", "common domain, spec"),
    start("10:09:01", "SPEC-001", 10, "WRITE", "spec-writer", HAIKU, "high"), end("10:15:00", "SPEC-001", 10, "WRITE", "spec-writer", 359),
    done("10:15:01", "spec-created", "SPEC-001", 10, "WRITE"),
    done("10:15:05", "spec-created", "SPEC-001", 10, "WRITE", { skipped: true }), // the driver re-enters the lane: WRITE is already done
    // PLAN: first on haiku (no plan.md), then retried on sonnet xhigh; the new shape carries tier, reasons and pass on the start event itself
    start("10:15:11", "SPEC-001", 11, "PLAN", "planner", HAIKU, "high", { tier: "fast", reasons: "agent default: balanced / high; common domain, plan: tier down", pass: "" }),
    end("10:18:00", "SPEC-001", 11, "PLAN", "planner", 169),
    start("10:18:02", "SPEC-001", 11, "PLAN", "planner", SONNET, "xhigh", { attempt: 2, log: "coordination/run/logs/state-11-SPEC-001-2.log", tier: "balanced", reasons: ["agent default: balanced / high", "attempt 2: tier up, effort up"] }),
    end("10:28:00", "SPEC-001", 11, "PLAN", "planner", 598, { attempt: 2, log: "coordination/run/logs/state-11-SPEC-001-2.log" }),
    done("10:28:01", "plan-created", "SPEC-001", 11, "PLAN"),
    sel("10:28:10", "SPEC-001", "implementer", "wave 1", "balanced", SONNET, "high", "agent default: balanced / medium; CR-7 risk: at least balanced, effort high"),
    start("10:28:11", "SPEC-001", 15, "IMPLEMENT", "implementer", SONNET, "high", { wave: 1 }), end("10:48:00", "SPEC-001", 15, "IMPLEMENT", "implementer", 1189, { wave: 1 }),
    done("10:48:01", "implement-completed", "SPEC-001", 15, "IMPLEMENT", { wave: "1" }),
    // TEST twice with one log name: the first run's log was overwritten by the second
    sel("10:48:10", "SPEC-001", "verifier", "spec", "balanced", SONNET, "xhigh", "agent default: balanced / high; extra-high complexity: effort xhigh", "full"),
    start("10:48:11", "SPEC-001", 16, "TEST", "verifier", SONNET, "xhigh"), end("11:08:11", "SPEC-001", 16, "TEST", "verifier", 1200),
    ev("11:08:12", "human-gate-triggered", "SPEC-001", { gate: "quality-deferred-on-exit-3", gate_id: "GATE-001", kind: "failure", state: 16, state_name: "TEST", reason: "a required tool is missing", allowed_answers: ["install", "accept-deferred", "abort"], gate_file: "coordination/gates/GATE-001.md", source: "kcc-run" }),
    ev("11:08:15", "human-gate-decision", "SPEC-001", { gate: "quality-deferred-on-exit-3", gate_id: "GATE-001", answer: "accept-deferred", answered_by: "policy", state: 16, note: "silent run: deferred quality check accepted by policy (not a pass)", source: "kcc-run" }),
    done("11:08:16", "test-completed", "SPEC-001", 16, "TEST"),
    start("11:08:20", "SPEC-001", 19, "FIX", "implementer", SONNET, "xhigh"), end("11:10:00", "SPEC-001", 19, "FIX", "implementer", 100),
    sel("11:10:08", "SPEC-001", "verifier", "spec", "balanced", SONNET, "high", "agent default: balanced / high; effort capped at high for review", "scoped"),
    start("11:10:10", "SPEC-001", 16, "TEST", "verifier", SONNET, "high"), end("11:20:10", "SPEC-001", 16, "TEST", "verifier", 600),
  ];
  put(".kcc-lanes/SPEC-001/coordination/backchannel.jsonl", l1.join("\n") + "\n");
  put(".kcc-lanes/SPEC-001/coordination/run/run.json", JSON.stringify({ status: "stopped", reason: "needs attention", state: "16", created: T("10:09:00"), updated: T("11:20:11"), fasttrack: "1" }));
  logFile("SPEC-001", "state-11-SPEC-001-1.log", "10:15:11", "10:18:00", "planner", HAIKU, "high");
  logFile("SPEC-001", "state-11-SPEC-001-2.log", "10:18:02", "10:28:00", "planner", SONNET, "xhigh");
  logFile("SPEC-001", "state-16-SPEC-001-1.log", "11:10:10", "11:20:10", "verifier", SONNET, "high"); // the first TEST's log is gone

  const l2 = [
    ...main,
    sel("10:09:01", "SPEC-002", "spec-writer", "spec", "fast", HAIKU, "high", "common domain, spec"),
    start("10:09:02", "SPEC-002", 10, "WRITE", "spec-writer", HAIKU, "high"), end("10:13:00", "SPEC-002", 10, "WRITE", "spec-writer", 238),
    done("10:13:01", "spec-created", "SPEC-002", 10, "WRITE"),
    sel("10:13:00", "SPEC-002", "planner", "plan", "fast", HAIKU, "high", "common domain, plan"),
    start("10:13:01", "SPEC-002", 11, "PLAN", "planner", HAIKU, "high"), end("10:20:00", "SPEC-002", 11, "PLAN", "planner", 419),
    done("10:20:01", "plan-created", "SPEC-002", 11, "PLAN"),
    ev("10:20:30", "human-gate-triggered", "SPEC-002", { gate: "ruling", gate_id: "GATE-002", kind: "ruling", state: 19, state_name: "FIX", reason: "Bug-003 needs a ruling", allowed_answers: ["revise", "waive", "abort"], source: "kcc-run" }),
    ev("10:50:30", "human-gate-decision", "SPEC-002", { gate: "ruling", gate_id: "GATE-002", answer: "revise", state: 19, note: "Option A approved", source: "kcc-run" }),
  ];
  put(".kcc-lanes/SPEC-002/coordination/backchannel.jsonl", l2.join("\n") + "\n");
  put(".kcc-lanes/SPEC-002/coordination/run/run.json", JSON.stringify({ status: "stopped", reason: "done", state: "19", created: T("10:09:01"), updated: T("10:50:31"), fasttrack: "1" }));

  // a review that quotes an earlier verdict in its text but whose own verdict is QUALITY_DEFERRED
  for (const s of ["SPEC-001", "SPEC-002"]) put(`specs/IDEA-001-demo-Specs/${s}-x/${s}-x.md`, `# ${s}: part\n\n| Status | Priority |\n|---|---|\n| In progress | P1 |\n`);
  put(".kcc-lanes/SPEC-001/specs/IDEA-001-demo-Specs/SPEC-001-x/SPEC-001-x.md", "# SPEC-001: part\n\n| Status | Priority |\n|---|---|\n| In progress | P1 |\n");
  put(".kcc-lanes/SPEC-001/specs/IDEA-001-demo-Specs/SPEC-001-x/review.md", "---\nspec: SPEC-001\nverdict: QUALITY_DEFERRED\n---\n\n# Review\n\nThe previous review (verdict CHANGES_NEEDED) verified the first commit.\n\n## Verdict\n**QUALITY_DEFERRED** (not a pass)\n");

  // the generated agent profiles: the default model and effort each agent has (the page compares every run with them)
  const prof = (name: string, model: string, effort: string): void => put(`.claude/agents/${name}.md`, `---
name: ${name}
model: ${model}
effort: ${effort}
---

x
`);
  prof("spec-writer", SONNET, "high"); prof("planner", SONNET, "high"); prof("implementer", SONNET, "medium"); prof("verifier", SONNET, "high"); prof("idea-interrogator", SONNET, "high"); prof("architect", SONNET, "high");

  // what kcc-run writes under --silent --assume
  put("coordination/NeedsAttention.md", [
    "# Needs attention", "", "Written by kcc-run under --silent --assume.", "", "- status: decided = the run went on; check the decision.", "",
    "## [decided] SPEC-001 | quality-deferred-on-exit-3 | state 16 TEST | 2026-10-16T11:08:15Z", "",
    "- when: 2026-10-16T11:08:15Z", "- spec: SPEC-001", "- state: 16 TEST", "- gate: quality-deferred-on-exit-3", "- status: decided",
    "- decided: accepted the deferred check by policy (not a pass)", "- why: semgrep is not installed", "- todo: install semgrep, then re-run quality-gate -Spec SPEC-001", "- links: coordination/gates/GATE-001.md, [review](specs/IDEA-001-demo-Specs/SPEC-001-x/review.md)", "",
    "## [open] SPEC-002 | ruling | state 19 FIX | 2026-10-16T10:50:30Z", "",
    "- when: 2026-10-16T10:50:30Z", "- spec: SPEC-002", "- state: 19 FIX", "- gate: ruling", "- status: open",
    "- decided: the spec was left (needs attention)", "- why: Bug-003 needs an architect ruling", "- todo: decide option A, B or C, then: kcc run --lane SPEC-002 --from 19", "- links: coordination/gates/GATE-002.md", "",
  ].join("\n"));

  const r = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
  expect(r.status).toBe(0);
  html = readFileSync(join(root, "dashboard", "index.html"), "utf8");
  D = JSON.parse(/<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/.exec(html)![1]!);
  for (const l of D.lanes) l.updated = T("11:20:11");

  const tpl = payloadFiles().get("kernel/templates/dashboard.html")!.toString("utf8");
  const part = (a: string, b: string): string => tpl.split(a)[1]!.split(b)[0]!;
  const stubs = `function esc(s){return (s==null?'':String(s)).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
    function fmtDur(ms){return Math.round((Number(ms)||0)/1000)+'s';}
    function modelShort(m){return String(m||'').replace(/^claude-/,'');}
    function approved(s){return false;}`;
  fns = new Function(`${stubs}\n${part("/*stage-timing:start*/", "/*stage-timing:end*/")}\n${part("/*needs-attention:start*/", "/*needs-attention:end*/")}\n${part("/*parallel-view:start*/", "/*parallel-view:end*/")}\nreturn { stageTimes, gateSpans, choiceOf, dispatchList, parseNeedsAttention, attentionItems, buildRuns, markOpen, flowScopes, runChoice, whyPlain };`)();
});

const NOW = ms("11:30:00");
const row = (st: any, name: string) => st.rows.find((r: any) => r.name === name);
const hms = (v: number): string => new Date(v).toISOString().slice(11, 19);

describe("stage numbers count what ran in the lanes", () => {
  test("the page data holds the lane events the workspace file lacks, and the re-run logs", () => {
    expect(D.events.length).toBe(7); // the workspace backchannel: run-wide only
    expect(D.laneEvents.some((e: any) => e.kind === "agent-run-started" && e.lane === "SPEC-001")).toBe(true);
    expect(D.laneEvents.some((e: any) => e.kind === "agent-run-ended" && e.lane === "SPEC-002")).toBe(true);
    expect(D.laneEvents.filter((e: any) => e.kind === "auto-policy-parsed").length).toBe(0); // the copy of the run-wide events is not repeated
    expect(D.runLogs.filter((l: any) => l.state === 11).length).toBe(2); // state-11-SPEC-001-1.log and -2.log
  });

  test("WRITE and PLAN have rows, with every dispatch (a retry is a dispatch) and overlap counted once", () => {
    const st = fns.stageTimes(D, NOW);
    const w = row(st, "WRITE"), p = row(st, "PLAN");
    expect(w.attempts).toBe(2);
    expect(hms(w.agentMs)).toBe("00:05:59"); // 10:09:01 -> 10:15:00; SPEC-002's WRITE ran inside it
    expect(w.sumMs).toBe((359 + 238) * 1000);
    expect(p.attempts).toBe(3); // SPEC-001 planner x2 (the retry) + SPEC-002 planner
    expect(hms(p.agentMs)).toBe("00:14:59"); // 10:13:01 -> 10:28:00, the three plans overlap
    expect(w.models).toBe("haiku high x2");
    expect(p.models).toBe("haiku high x2, sonnet xhigh x1");
  });

  test("a TEST that ran twice under one log name is two dispatches, not one 8-second row", () => {
    const st = fns.stageTimes(D, NOW);
    const t = row(st, "TEST");
    expect(t.attempts).toBe(2);
    expect(hms(t.agentMs)).toBe("00:30:00"); // 20 min + 10 min
    expect(row(st, "IMPLEMENT").attempts).toBe(1);
    expect(row(st, "FIX").attempts).toBe(1);
  });

  test("totals: dispatches, agent time with overlap counted once, wall clock first to last event, human time from the lanes' gates", () => {
    const st = fns.stageTimes(D, NOW);
    expect(st.totals.dispatches).toBe(12);
    expect(hms(st.totals.agentWallMs)).toBe("01:18:25");
    expect(hms(st.totals.agentSumMs)).toBe("01:29:09");
    expect(hms(st.totals.wallMs)).toBe("01:20:10"); // 10:00:00 -> 11:20:10
    const gates = fns.gateSpans(D, NOW);
    expect(gates.length).toBe(2);
    expect(gates.filter((g: any) => g.auto).length).toBe(1); // GATE-001 was answered by policy
    expect(hms(row(st, "FIX").humanMs)).toBe("00:30:00"); // GATE-002, a lane gate
    expect(st.totals.humanMs).toBe(30 * 60000);
  });

  test("with no dispatch events the stage comes from the dispatch logs (a lane's logs included)", () => {
    const noEv = { ...D, events: [], laneEvents: [] };
    const st = fns.stageTimes(noEv, NOW);
    expect(row(st, "PLAN").attempts).toBe(2);
    expect(hms(row(st, "PLAN").agentMs)).toBe("00:12:47"); // the two logs: 2:49 + 9:58
    expect(row(st, "TEST").attempts).toBe(1); // what a log of a re-run that overwrote the first one can show: the honest limit
  });
});

describe("kcc report counts the same lane runs", () => {
  const at = { skeletonMin: 45, appMin: 180, srcFiles: 3, now: NOW };

  test("the report lists WRITE, PLAN and TEST with their dispatches, the agent and wall time, and the human gates", () => {
    const r = buildReport(html, at);
    expect(r.markdown).toMatch(/\| 10 WRITE \| 2 \| 00:05:59 \|/);
    expect(r.markdown).toMatch(/\| 11 PLAN \| 3 \| 00:14:59 \|/);
    expect(r.markdown).toMatch(/\| 16 TEST \| 2 \| 00:30:00 \|/);
    expect(r.markdown).toContain("Wall clock 01:20:10");
    expect(r.markdown).toContain("agents 01:18:25 with runs that overlap counted once (01:29:09 with every run added up), across 12 dispatches");
    expect(r.markdown).toContain("waiting on the human 00:30:00 across 1 gate; 1 gate answered by policy, not counted as a wait");
    expect(r.markdown).toContain("haiku high x2, sonnet xhigh x1");
  });

  test("the report reads the lanes' own backchannels from disk when the page does not hold their events", () => {
    const blank = html.replace(/(<script id="kcc-data" type="application\/json">)([\s\S]*?)(<\/script>)/, (_m, a, body, c) => {
      const d = JSON.parse(body);
      d.laneEvents = [];
      return a + JSON.stringify(d).replace(/<\//g, "<\\/") + c;
    });
    const without = buildReport(blank, at);
    expect(without.markdown).not.toContain("| 10 WRITE |"); // WRITE ran in the lanes only: invisible without their events
    expect(without.markdown).not.toContain("across 12 dispatches");
    expect(without.markdown).toContain("Wall clock 00:08:00"); // and the wall clock stops at the last run-wide event
    const lanes = readLaneEvents(root);
    expect(lanes.length).toBeGreaterThan(30);
    const withLanes = buildReport(blank, { ...at, laneEvents: lanes });
    expect(withLanes.markdown).toContain("across 12 dispatches");
    expect(withLanes.markdown).toMatch(/\| 16 TEST \| 2 \| 00:30:00 \|/);
    expect(withLanes.markdown).toContain("Wall clock 01:20:10");
    // the events both the page and the disk hold are counted once
    expect(buildReport(html, { ...at, laneEvents: lanes }).markdown).toContain("across 12 dispatches");
  });

  test("the command reads the lane backchannels itself (kcc report --no-build on the page as it is)", () => {
    const lines: string[] = [];
    const log = console.log;
    console.log = (...a: unknown[]) => { lines.push(a.join(" ")); };
    try { report(["--dir", root, "--no-build"]); } finally { console.log = log; }
    const out = lines.join("\n");
    expect(out).toContain("across 12 dispatches");
    expect(out).toContain("| 16 TEST | 2 | 00:30:00 |");
  });

  test("the model and effort choices are in the report, with the reason", () => {
    const r = buildReport(html, { ...at, laneEvents: readLaneEvents(root) });
    expect(r.markdown).toContain("## Model and effort choices");
    expect(r.markdown).toMatch(/\| planner \| PLAN \| sonnet \/ xhigh \| .*retry 2 \| .*attempt 2/);
    expect(r.markdown).toMatch(/\| spec-writer \| WRITE \| haiku \/ high \| haiku lowered from the balanced default \| common domain, spec \| 2 \|/);
  });
});

describe("the router's reasons reach the page", () => {
  const dispatches = () => fns.dispatchList(D);
  const find = (state: number, spec: string, attempt = "") => dispatches().find((d: any) => d.state === state && d.spec === spec && (attempt === "" || String(d.attempt) === attempt));

  test("reasons come from the start event, else from the model-selected event just before it", () => {
    const a2 = find(11, "SPEC-001", "2");
    expect(a2.tier).toBe("balanced");
    expect(a2.reasons).toEqual(["agent default: balanced / high", "attempt 2: tier up, effort up"]); // start event payload (array form)
    expect(a2.why).toBe("start event");
    const w = find(10, "SPEC-001");
    expect(w.reasons).toBe("common domain, spec"); // joined from model-selected
    expect(w.tier).toBe("fast");
    expect(w.why).toBe("model-selected event");
    expect(find(16, "SPEC-001", "1").pass).toBe("full");
  });

  test("a non-default choice is explained in words; a default run is not flagged; a retry is", () => {
    const c = (d: any) => fns.choiceOf(d, D);
    const retry = c(find(11, "SPEC-001", "2"));
    expect(retry.differs).toBe(true);
    expect(retry.short).toContain("retry 2");
    expect(retry.why).toEqual(["attempt 2: tier up, effort up"]);
    const eff = c(find(16, "SPEC-001", "1"));
    expect(eff.short).toContain("effort raised to xhigh (default high)");
    expect(eff.whyText).toBe("extra-high complexity: effort xhigh");
    const haiku = c(find(10, "SPEC-001"));
    expect(haiku.short[0]).toBe("haiku lowered from the balanced default"); // default from the agent profile when the router logged none
    expect(haiku.flags[0]).toContain("common domain, spec");
    const idea = c(dispatches().find((d: any) => d.state === 1));
    expect(idea.differs).toBe(false);
    expect(idea.recorded).toBe(false); // no model-selected event: the page says so instead of inventing a reason
    expect(fns.whyPlain({ kind: "session", disp: dispatches().find((d: any) => d.state === 1), model: SONNET, effort: "high", tier: "balanced", agent: "idea-interrogator" }, D)).toBe("no reason recorded");
  });

  test("runs carry the reasons, an orchestrator session is named, and the timeline row is marked", () => {
    const rb = fns.markOpen(D, fns.buildRuns(D, NOW), NOW);
    const planRetry = rb.runs.find((r: any) => r.state === 11 && r.spec === "SPEC-001" && r.model === SONNET);
    expect(fns.runChoice(planRetry, D).short).toContain("retry 2");
    expect(rb.runs.filter((r: any) => r.kind !== "subagent").every((r: any) => r.agent)).toBe(true);
  });
});

describe("honesty fixes", () => {
  test("a review's own verdict (frontmatter) wins over a verdict it quotes, and QUALITY_DEFERRED is its own state", () => {
    const s = D.specs.find((x: any) => x.id === "SPEC-001");
    expect(s.review.verdict).toBe("QUALITY_DEFERRED");
  });

  test("a state the driver found already done is not a second visit of the flowchart", () => {
    const rb = fns.markOpen(D, fns.buildRuns(D, NOW), NOW);
    const F = fns.flowScopes(D, rb, NOW);
    const sp = F.specs.find((x: any) => x.id === "SPEC-001");
    const write = D.states.find((s: any) => s.name === "WRITE").id;
    expect(sp.N[write].visits).toBe(1);
    expect(sp.N[write].skipped).toBe(false);
    expect(sp.N[write].retries).toBe(0);
    const plan = D.states.find((s: any) => s.name === "PLAN").id;
    expect(sp.N[plan].visits).toBe(2); // the retry is real
    expect(sp.N[plan].retries).toBe(1);
  });
});

describe("needs attention", () => {
  test("both builders hand the page the NeedsAttention.md text; the page parses sections and key: value lines", () => {
    expect(D.needsAttention.length).toBe(1);
    expect(D.needsAttention[0].file).toBe("coordination/NeedsAttention.md");
    const items = fns.attentionItems(D);
    expect(items.length).toBe(2);
    expect(items[0]).toMatchObject({ spec: "SPEC-001", status: "decided", gate: "quality-deferred-on-exit-3", state: "16 TEST", source: "file" });
    expect(items[0].decision).toContain("accepted the deferred check");
    expect(items[0].check).toContain("install semgrep");
    expect(items[0].links).toContain("coordination/gates/GATE-001.md");
    expect(items[0].links).toContain("specs/IDEA-001-demo-Specs/SPEC-001-x/review.md");
    expect(items[1]).toMatchObject({ spec: "SPEC-002", status: "open", gate: "ruling" });
  });

  test("the parser is tolerant: other headings, bold keys and synonyms still give an item", () => {
    const items = fns.parseNeedsAttention([{ file: "x.md", text: "## Budget gate on SPEC-003\n\n- **When:** 2026-10-16T09:00:00Z\n- **Decision:** continue\n- **Reason:** silent run\n- **What to check:** the cost\n" }]);
    expect(items.length).toBe(1);
    expect(items[0]).toMatchObject({ spec: "SPEC-003", when: "2026-10-16T09:00:00Z", decision: "continue", why: "silent run", check: "the cost" });
  });

  test("without the file the items come from the events the policy answered, and the needs-attention events", () => {
    const noFile = { ...D, needsAttention: [] };
    const items = fns.attentionItems(noFile);
    expect(items.length).toBe(1); // GATE-001 (policy); GATE-002 was answered by a person
    expect(items[0]).toMatchObject({ spec: "SPEC-001", gate: "quality-deferred-on-exit-3", status: "decided", source: "events" });
    const withEv = { ...noFile, laneEvents: [...D.laneEvents, { ts: T("11:09:00"), kind: "needs-attention", spec: "SPEC-002", payload: { state: 19, state_name: "FIX", gate: "ruling", status: "open", decided: "left", reason: "ruling needed", todo: "decide", file: "coordination/NeedsAttention.md" } }] };
    expect(fns.attentionItems(withEv).map((x: any) => x.status).sort()).toEqual(["decided", "open"]);
  });
});

describe("rendered page", () => {
  test("shows the Needs attention card, the choices card, WRITE and PLAN in the stage table (skipped when no browser is installed)", () => {
    const dom = renderHeadless(join(root, "dashboard", "index.html"));
    if (dom === undefined) return;
    expect(dom).toContain('id="attn"');
    expect(dom).toContain("2 need attention");
    expect(dom).toContain("Model and effort choices");
    expect(dom).toContain("haiku lowered from the balanced default");
    expect(dom).toMatch(/<b>10<\/b> WRITE/);
    expect(dom).toMatch(/<b>11<\/b> PLAN/);
    expect(dom).toContain("0 of 2 specs delivered (approved)");
    expect(dom).toContain("quality deferred");
    expect(dom).toContain("auto-decided by policy");
  });
});
