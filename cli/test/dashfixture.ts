import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { applyPayload } from "../src/lock";
import { runTool } from "../src/platform";

// A synthetic workspace for the dashboard browser tests: N specs whose WRITE, PLAN, IMPLEMENT and TEST runs overlap, a human gate, and (when
// `running`) one agent still working at `nowIso`. The page is built with the real builder, so the template under test is the one the repo ships.
export interface DashFixture {
  root: string;
  file: string;
  nowIso: string;
  data: any;
  runs: number;
}

const iso = (baseMs: number, min: number): string => new Date(baseMs + min * 60000).toISOString().replace(/\.\d+Z$/, "Z");

export function makeDashWorkspace(opts: { specs?: number; spreadMin?: number; running?: boolean; baseIso?: string; template?: string } = {}): DashFixture {
  const root = mkdtempSync(join(tmpdir(), "kcc-dashfx-"));
  applyPayload(root);
  if (opts.template) writeFileSync(join(root, ".KCC", "kernel", "templates", "dashboard.html"), readFileSync(opts.template, "utf8"));
  const base = Date.parse(opts.baseIso ?? "2026-10-16T08:00:00Z");
  const nSpecs = opts.specs ?? 2;
  const spread = opts.spreadMin ?? 20;
  const put = (rel: string, text: string): void => {
    const p = join(root, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, text);
  };
  let n = 0;
  const lines: Array<{ ts: string; line: string }> = [];
  const add = (min: number, kind: string, spec: string | null, payload: Record<string, unknown>): void => {
    const ts = iso(base, min);
    lines.push({ ts, line: JSON.stringify({ ts, id: `BC-${String(++n).padStart(5, "0")}`, from: "kcc-run", to: "broadcast", kind, spec, session: null, payload }) });
  };
  const MODELS = ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5"];
  const stages: Array<[number, string, string, number]> = [[10, "WRITE", "spec-writer", 6], [11, "PLAN", "planner", 11], [15, "IMPLEMENT", "implementer", 25], [16, "TEST", "verifier", 14]];
  let runs = 0;
  let lastEnd = 0;
  let openRun: [string, number, string, string, number] | null = null;
  const specIds: string[] = [];
  for (let s = 0; s < nSpecs; s++) {
    const spec = `SPEC-${String(s + 1).padStart(3, "0")}`;
    specIds.push(spec);
    let t = (s * spread) % (Math.max(1, nSpecs) * spread) + s * 2;
    stages.forEach(([state, name, agent, mins], k) => {
      const model = MODELS[(s + k) % 3]!;
      const start = t, endm = t + mins + (s % 4);
      const payload = { state, state_name: name, agent, model, effort: "high", attempt: 1, wave: state === 15 ? 1 : "", log: `coordination/run/logs/state-${state}-${spec}-1.log`, started: iso(base, start), source: "kcc-run" };
      add(start, "agent-run-started", spec, payload);
      runs++;
      if (opts.running && s === nSpecs - 1 && k === 3) openRun = [spec, start, name, agent, state];
      else {
        add(endm, "agent-run-ended", spec, { state, state_name: name, agent, attempt: 1, wave: state === 15 ? 1 : "", exit: 0, seconds: (endm - start) * 60, ended: iso(base, endm), source: "kcc-run" });
        lastEnd = Math.max(lastEnd, endm);
      }
      t = endm + 1;
      if (k === 1 && s === 0) {
        add(t, "human-gate-opened", spec, { gate_id: "GATE-001", gate_name: "ruling", state: 15, question: "Which option?", answers: ["A", "B"] });
        add(t + 9, "human-gate-decision", spec, { gate_id: "GATE-001", gate_name: "ruling", state: 15, answer: "A", by: "human" });
        t += 10;
      }
    });
    put(`specs/IDEA-001-demo-Specs/${spec}-x/${spec}-x.md`, `# ${spec}: part ${s + 1}\n\n| Status | Priority |\n|---|---|\n| In progress | P1 |\n`);
  }
  const firstStart = 0;
  const lastMin = Math.max(lastEnd, openRun ? openRun[1] + 4 : 0);
  const nowIso = iso(base, lastMin + 0.5);
  lines.sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0));
  put("coordination/backchannel.jsonl", lines.map((l) => l.line).join("\n") + "\n");
  put("coordination/run/run.json", JSON.stringify({ status: opts.running ? "running" : "stopped", reason: opts.running ? "" : "fixture", state: "16", scenario: "S2", fasttrack: "1", created: iso(base, firstStart), updated: nowIso, idea: "IDEA-001-demo", specs: specIds.map((s) => `IDEA-001-demo/${s}-x`).join(" "), spec_index: "0" }));
  const r = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
  if (r.status !== 0) throw new Error("build-dashboard failed: " + (r.stderr || r.stdout));
  const file = join(root, "dashboard", "index.html");
  const html = readFileSync(file, "utf8");
  const data = JSON.parse(/<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/.exec(html)![1]!);
  return { root, file, nowIso, data, runs };
}

export const fileUrl = (f: string, q = ""): string => "file:///" + f.replace(/\\/g, "/").replace(/^\/+/, "") + (q ? "?" + q : "");
