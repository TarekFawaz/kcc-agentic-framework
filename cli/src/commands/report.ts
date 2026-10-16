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
 */
interface Row { id: number; name: string; skipped: boolean; attempts: number; agentMs: number; humanMs: number; totalMs: number }
interface Timing { stageTimes(D: unknown, now: number): { rows: Row[]; totals: { agentMs: number; humanMs: number; totalMs: number } }; gateSpans(D: unknown, now: number): { start: number; end: number; openNow?: boolean }[]; toMs(s: string): number | null; fmtHMS(ms: number): string }

const SKELETON_KINDS = new Set(["implement-completed", "test-completed", "review-produced"]);

export function loadTiming(html: string): Timing {
  const m = /\/\*stage-timing:start\*\/([\s\S]*?)\/\*stage-timing:end\*\//.exec(html);
  if (!m) throw new UsageError("the dashboard page has no stage-timing block (run kcc upgrade, then kcc dashboard)");
  return new Function(`${m[1]}; return { stageTimes, gateSpans, toMs, fmtHMS };`)() as Timing;
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

export interface ReportOptions { skeletonMin: number; appMin: number; srcFiles: number; now?: number }
export interface ReportResult { markdown: string; pass: boolean; incomplete: boolean; skeletonMs: number | null; appMs: number | null }

export function buildReport(html: string, o: ReportOptions): ReportResult {
  const data = /<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/.exec(html);
  if (!data) throw new UsageError("the dashboard page has no kcc-data block");
  const D = JSON.parse(data[1]!) as Record<string, any>;
  const T = loadTiming(html);
  // The page parses object payloads at load; do the same so the timing functions see the gate ids.
  for (const e of D.events ?? []) if (typeof e.payload === "string" && /^[\[{]/.test(e.payload)) { try { e.payload = JSON.parse(e.payload); } catch { /* keep the string */ } }
  const events: { ts: string; kind: string; spec?: string }[] = D.events ?? [];
  const stamps = events.map((e) => T.toMs(e.ts)).filter((x): x is number => x != null);
  const run = D.run ?? {};
  const start = Math.min(...stamps, T.toMs(run.created) ?? Infinity);
  const lastStamp = Math.max(...stamps, T.toMs(run.updated) ?? 0);
  const end = /running/.test(run.status ?? "") ? (o.now ?? Date.now()) : lastStamp;
  if (!isFinite(start)) throw new UsageError("no events and no run.json: there is nothing to measure");

  const st = T.stageTimes(D, end);
  const gates = T.gateSpans(D, end);
  const humanMs = gates.reduce((s, g) => s + Math.max(0, g.end - g.start), 0);
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
  if (!pass && !incomplete && slow.length) L.push(`Slowest stages: ${slow.map((r) => `${r.name} ${f(r.totalMs)}`).join(", ")}.`, "");
  L.push(`## Time`, "", `Wall clock ${f(wall)}; agents ${f(st.totals.agentMs)}; waiting on the human ${f(humanMs)} across ${gates.length} gate${gates.length === 1 ? "" : "s"}.`, "");
  L.push(`| Stage | Attempts | Agent | Human | Total |`, `|--|--|--|--|--|`);
  for (const r of st.rows) if (!r.skipped && r.totalMs > 0) L.push(`| ${r.id} ${r.name} | ${r.attempts} | ${f(r.agentMs)} | ${f(r.humanMs)} | ${f(r.totalMs)} |`);
  L.push("", `## Agents and cost`, "", `${agents.length} agent run${agents.length === 1 ? "" : "s"}, ${totalCost ? `about $${totalCost.toFixed(2)}` : "no cost data"}.`, "");
  if (byModel.size) { L.push(`| Model | Runs | Cost | Time |`, `|--|--|--|--|`); for (const [k, e] of byModel) L.push(`| ${k} | ${e.n} | $${e.cost.toFixed(2)} | ${f(e.ms)} |`); L.push(""); }
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
  const r = buildReport(readFileSync(file, "utf8"), { skeletonMin: num(values["skeleton-min"], 45), appMin: num(values["app-min"], 180), srcFiles: countFiles(join(root, "src")) });
  if (typeof values.out === "string") {
    const out = resolve(values.out);
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, r.markdown + "\n");
    console.log(`Report: ${out} (${r.pass ? "PASS" : r.incomplete ? "INCOMPLETE" : "FAIL"})`);
  } else console.log(r.markdown);
  return r.pass ? 0 : r.incomplete ? 2 : 1;
}
