import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { parse, UsageError, workspace } from "../args";
import { runTool } from "../platform";

/**
 * `kcc report [--skeleton-min N] [--app-min N] [--out file] [--no-build]`
 *
 * One run, measured: stages, human waits, agents, cost, outcome, and a verdict against a time budget
 * (default: a walking skeleton within 45 minutes, the whole app within 180). Exit 0 pass, 1 miss, 2 incomplete (the
 * run has not closed and is still inside the budget: resume it). It reads the dashboard's data
 * block and runs the dashboard's own stage-timing functions (the block between the stage-timing markers),
 * so the report and the page cannot disagree. Exit 1 when a budget is missed, naming the slowest stages.
 *
 * Stage numbers are built from the agent-run-started / agent-run-ended events of the workspace backchannel AND of every lane
 * (`.kcc-lanes/*` and `.worktrees/*` keep their own coordination/backchannel.jsonl; WRITE, PLAN and everything a spec does in
 * its lane is only there until it is synced), so a stage that ran in a lane is counted, and a stage that ran again (TEST three
 * times) counts every dispatch. Overlapping dispatches of one stage count once as wall time; human time comes from the gates.
 */
interface Row { id: number; name: string; skipped: boolean; attempts: number; agentMs: number; humanMs: number; totalMs: number; sumMs?: number; models?: string }
interface Disp { state: number; spec: string; agent: string; model: string; effort: string; tier: string; reasons: unknown; attempt: string; pass: unknown; start: number; end: number; open?: boolean; cut?: boolean }
interface Choice { differs: boolean; recorded: boolean; whyText: string; short: string[]; family: string; effort: string; tier: string; def: { tier: string; effort: string } | null }
interface Totals { agentMs: number; humanMs: number; totalMs: number; agentWallMs?: number; agentSumMs?: number; dispatches?: number; wallMs?: number }
interface Timing {
  stageTimes(D: unknown, now: number): { rows: Row[]; totals: Totals; dispatches?: Disp[] };
  gateSpans(D: unknown, now: number): { start: number; end: number; openNow?: boolean; auto?: boolean }[];
  runEvents(D: unknown): { ts: string; kind: string; spec?: string; payload?: unknown }[];
  choiceOf(d: Disp, D: unknown): Choice;
  toMs(s: string): number | null;
  fmtHMS(ms: number): string;
}

const SKELETON_KINDS = new Set(["implement-completed", "test-completed", "review-produced"]);

export function loadTiming(html: string): Timing {
  const m = /\/\*stage-timing:start\*\/([\s\S]*?)\/\*stage-timing:end\*\//.exec(html);
  if (!m) throw new UsageError("the dashboard page has no stage-timing block (run kcc upgrade, then kcc dashboard)");
  return new Function(`${m[1]}; return { stageTimes, gateSpans, runEvents, choiceOf, toMs, fmtHMS };`)() as Timing;
}

function countFiles(dir: string, cap = 5000): number {
  let n = 0;
  const walk = (d: string): void => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      if (n >= cap) return;
      if (e.name === "node_modules" || e.name === ".git") continue;
      if (e.isDirectory()) walk(join(d, e.name));
      else n++;
    }
  };
  if (existsSync(dir) && statSync(dir).isDirectory()) walk(dir);
  return n;
}

/** The events of every lane's own backchannel (`.kcc-lanes/*`, `.worktrees/*`), tagged with the lane. Unparseable lines are skipped. */
export function readLaneEvents(root: string): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  for (const base of [".kcc-lanes", ".worktrees"]) {
    const dir = join(root, base);
    if (!existsSync(dir) || !statSync(dir).isDirectory()) continue;
    for (const lane of readdirSync(dir, { withFileTypes: true })) {
      if (!lane.isDirectory()) continue;
      const file = join(dir, lane.name, "coordination", "backchannel.jsonl");
      if (!existsSync(file)) continue;
      for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
        if (!line.trim()) continue;
        try { out.push({ ...(JSON.parse(line) as Record<string, unknown>), lane: lane.name }); } catch { /* a half-written line */ }
      }
    }
  }
  return out;
}

export interface ReportOptions { skeletonMin: number; appMin: number; srcFiles: number; now?: number; laneEvents?: Record<string, unknown>[] }
export interface ReportResult { markdown: string; pass: boolean; incomplete: boolean; skeletonMs: number | null; appMs: number | null }

export function buildReport(html: string, o: ReportOptions): ReportResult {
  const data = /<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/.exec(html);
  if (!data) throw new UsageError("the dashboard page has no kcc-data block");
  const D = JSON.parse(data[1]!) as Record<string, any>;
  const T = loadTiming(html);
  // The page parses object payloads at load; do the same so the timing functions see the gate ids.
  const parsePayload = (e: any): void => { if (typeof e.payload === "string" && /^[\[{]/.test(e.payload)) { try { e.payload = JSON.parse(e.payload); } catch { /* keep the string */ } } };
  for (const e of D.events ?? []) parsePayload(e);
  for (const e of D.laneEvents ?? []) parsePayload(e);
  // Events of the lanes' own backchannels (read from disk by the caller): added to the ones the page holds; an event both hold
  // (same ts, kind, spec and identifiers) is counted once by runEvents.
  D.laneEvents = [...(D.laneEvents ?? []), ...(o.laneEvents ?? [])];
  const events = T.runEvents(D) as { ts: string; kind: string; spec?: string }[];
  const stamps = events.map((e) => T.toMs(e.ts)).filter((x): x is number => x != null);
  const run = D.run ?? {};
  const running = /running/.test(run.status ?? "");
  const startsAt = T.toMs(run.created);
  // Wall clock: the first to the last event of the run (to now while it is still running).
  const first = Math.min(...stamps, ...(startsAt != null ? [startsAt] : []));
  const lastStamp = Math.max(...stamps, 0);
  const start = first;
  const end = running ? (o.now ?? Date.now()) : lastStamp;
  if (!isFinite(start)) throw new UsageError("no events and no run.json: there is nothing to measure");

  const st = T.stageTimes(D, end);
  const gates = T.gateSpans(D, end);
  const human = gates.filter((g) => !g.auto), auto = gates.filter((g) => g.auto);
  const humanMs = human.reduce((s, g) => s + Math.max(0, g.end - g.start), 0);
  const wall = end - start;
  const min = (ms: number): number => ms / 60000;

  const specs: { id: string; status?: string }[] = D.specs ?? [];
  const firstSpec = specs.map((s) => s.id).sort()[0] ?? events.map((e) => e.spec ?? "").filter((s) => /^SPEC-/.test(s)).sort()[0];
  const skel = events.find((e) => SKELETON_KINDS.has(e.kind) && e.spec === firstSpec);
  const closed = [...events].reverse().find((e) => e.kind === "session-closed");
  const skeletonMs = skel ? (T.toMs(skel.ts) ?? start) - start : null;
  const appMs = closed ? (T.toMs(closed.ts) ?? start) - start : null;
  const okSkel = skeletonMs != null && min(skeletonMs) <= o.skeletonMin;
  const okApp = appMs != null && min(appMs) <= o.appMin;
  const pass = okSkel && okApp && o.srcFiles > 0;
  // A run that never closed has not finished: inside the app budget that is "incomplete" (resume it), past it a miss.
  // A stopped or interrupted run must not read as a failed framework.
  const elapsed = (o.now ?? Date.now()) - start;
  const incomplete = !pass && !closed && min(elapsed) <= o.appMin;
  const label = pass ? "PASS" : incomplete ? "INCOMPLETE" : "FAIL";

  const agents: any[] = D.agents ?? [];
  const byModel = new Map<string, { n: number; cost: number; ms: number }>();
  for (const a of agents) {
    const k = String(a.model ?? "?");
    const e = byModel.get(k) ?? { n: 0, cost: 0, ms: 0 };
    e.n++; e.cost += Number(a.costUSD) || 0; e.ms += Number(a.durationMs) || 0;
    byModel.set(k, e);
  }
  const totalCost = [...byModel.values()].reduce((s, e) => s + e.cost, 0);
  const slow = [...st.rows].sort((a, b) => b.totalMs - a.totalMs).filter((r) => r.totalMs > 0).slice(0, 3);
  const f = T.fmtHMS;
  const verdict = (ok: boolean, ms: number | null, budget: number): string => (ms == null ? "FAIL (not reached)" : `${ok ? "PASS" : "FAIL"} (${f(ms)} of ${budget} min)`);

  const L: string[] = [];
  L.push(`# Round report`, "", `Generated ${new Date(o.now ?? Date.now()).toISOString()}; last event ${new Date(lastStamp).toISOString()}. Run status: **${run.status ?? "unknown"}**${run.reason ? ` (${run.reason})` : ""}. Flags: ${run.fasttrack === "1" ? "--fasttrack " : ""}${run.depthlevel ? `--depthlevel ${run.depthlevel}` : ""}`.trimEnd(), "");
  L.push(`## Verdict: ${label}`, "", `| Budget | Result |`, `|--|--|`, `| Walking skeleton (first spec built) | ${verdict(okSkel, skeletonMs, o.skeletonMin)} |`, `| Whole app (session closed) | ${verdict(okApp, appMs, o.appMin)} |`, `| Code written under src/ | ${o.srcFiles > 0 ? `PASS (${o.srcFiles} files)` : "FAIL (none)"} |`, "");
  if (incomplete) L.push(`The run has not closed (status ${run.status ?? "unknown"}${run.reason ? `: ${run.reason}` : ""}); ${f(elapsed)} of ${o.appMin} min used. Resume it with kcc run --resume, then run kcc report again.`, "");
  if (!pass && !incomplete && slow.length) L.push(`Slowest stages: ${slow.map((r) => `${r.name} ${f(r.totalMs)}${r.humanMs > r.agentMs ? " (mostly human wait)" : ""}`).join(", ")}.`, "");
  const t = st.totals;
  const sumNote = t.agentSumMs != null && t.agentWallMs != null && t.agentSumMs > t.agentWallMs * 1.02 ? ` (${f(t.agentSumMs)} with every run added up)` : "";
  L.push(`## Time`, "", `Wall clock ${f(wall)} (first to last event, lanes included); agents ${f(t.agentWallMs ?? t.agentMs)} with runs that overlap counted once${sumNote}, across ${t.dispatches ?? "?"} dispatches; waiting on the human ${f(humanMs)} across ${human.length} gate${human.length === 1 ? "" : "s"}${auto.length ? `; ${auto.length} gate${auto.length === 1 ? "" : "s"} answered by policy, not counted as a wait` : ""}.`, "");
  L.push(`| Stage | Dispatches | Agent | Human | Total | Models |`, `|--|--|--|--|--|--|`);
  for (const r of st.rows) if (!r.skipped && r.totalMs > 0) L.push(`| ${r.id} ${r.name} | ${r.attempts} | ${f(r.agentMs)} | ${f(r.humanMs)} | ${f(r.totalMs)} | ${r.models ?? ""} |`);
  L.push("", `## Agents and cost`, "", `${agents.length} agent run${agents.length === 1 ? "" : "s"}, ${totalCost ? `about $${totalCost.toFixed(2)}` : "no cost data"}.`, "");
  if (byModel.size) { L.push(`| Model | Runs | Cost | Time |`, `|--|--|--|--|`); for (const [k, e] of byModel) L.push(`| ${k} | ${e.n} | $${e.cost.toFixed(2)} | ${f(e.ms)} |`); L.push(""); }

  // Why a run used another tier or effort than its agent's default (the router's reasons, from the dispatch events).
  const disp = st.dispatches ?? [];
  if (disp.length) {
    const groups = new Map<string, { agent: string; stage: string; ran: string; changed: string; why: string; n: number }>();
    let none = 0;
    for (const d of disp) {
      const c = T.choiceOf(d, D);
      if (!c.recorded) none++;
      if (!c.differs) continue;
      const stage = st.rows.find((r) => r.id === d.state)?.name ?? String(d.state);
      const key = [d.agent, d.state, c.family, c.effort, c.whyText.replace(/\s*\([^)]*\)/g, ""), c.short.join("|")].join("#");
      const g = groups.get(key) ?? { agent: d.agent || "orchestrator", stage, ran: `${c.family} / ${c.effort || "?"}`, changed: c.short.join(", "), why: c.recorded ? c.whyText || "agent default" : "no reason recorded", n: 0 };
      g.n++; groups.set(key, g);
    }
    L.push(`## Model and effort choices`, "", `${[...groups.values()].reduce((s, g) => s + g.n, 0)} of ${disp.length} dispatches ran on a tier or effort other than the agent default, or were a retry${none ? `; ${none} have no recorded reason` : ""}.`, "");
    if (groups.size) { L.push(`| Agent | Stage | Ran as | Changed | Why | Runs |`, `|--|--|--|--|--|--|`); for (const g of [...groups.values()].sort((a, b) => b.n - a.n)) L.push(`| ${g.agent} | ${g.stage} | ${g.ran} | ${g.changed} | ${g.why} | ${g.n} |`); L.push(""); }
  }
  L.push(`## Output`, "", `${specs.length} spec${specs.length === 1 ? "" : "s"}: ${specs.map((s) => `${s.id} ${s.status ?? "?"}`).join(", ") || "none"}. ${o.srcFiles} file${o.srcFiles === 1 ? "" : "s"} under src/.`, "");
  const deep = events.filter((e) => e.kind === "deep-spawned").length;
  if (deep) L.push(`DeepThinking spawns: ${deep}.`, "");
  return { markdown: L.join("\n"), pass, incomplete, skeletonMs, appMs };
}

export function report(argv: string[]): number {
  const { values } = parse(argv, ["no-build"], ["dir", "skeleton-min", "app-min", "out"]);
  const root = workspace(values.dir);
  if (values["no-build"] !== true) {
    const b = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
    if (b.status !== 0) throw new UsageError("build-dashboard failed: " + (b.stderr || b.stdout).slice(-300));
  }
  const file = join(root, "dashboard", "index.html");
  if (!existsSync(file)) throw new UsageError("no dashboard/index.html (run kcc dashboard)");
  const num = (v: unknown, d: number): number => (typeof v === "string" && Number(v) > 0 ? Number(v) : d);
  const r = buildReport(readFileSync(file, "utf8"), { skeletonMin: num(values["skeleton-min"], 45), appMin: num(values["app-min"], 180), srcFiles: countFiles(join(root, "src")), laneEvents: readLaneEvents(root) });
  if (typeof values.out === "string") {
    const out = resolve(values.out);
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, r.markdown + "\n");
    console.log(`Report: ${out} (${r.pass ? "PASS" : r.incomplete ? "INCOMPLETE" : "FAIL"})`);
  } else console.log(r.markdown);
  return r.pass ? 0 : r.incomplete ? 2 : 1;
}
