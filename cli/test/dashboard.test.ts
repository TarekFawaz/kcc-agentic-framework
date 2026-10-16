import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { applyPayload } from "../src/lock";
import { payloadFiles } from "../src/payload";
import { runTool } from "../src/platform";

const root = mkdtempSync(join(tmpdir(), "kcc-dash-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

function put(rel: string, text: string): void {
  const p = join(root, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, text);
}

function pageData(): any {
  const html = readFileSync(join(root, "dashboard", "index.html"), "utf8");
  const m = html.match(/<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/);
  expect(m).not.toBeNull();
  return JSON.parse(m![1] as string);
}

describe("dashboard generator", () => {
  test("an empty workspace still produces a valid page", () => {
    applyPayload(root);
    const r = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
    expect(r.status).toBe(0);
    const d = pageData();
    expect(d.specs).toEqual([]);
    expect(d.run).toBeNull();
    const html = readFileSync(join(root, "dashboard", "index.html"), "utf8");
    expect(html).toContain("Tika&rsquo;s Way");
    expect(html).not.toContain("__KCC_DATA__");
  });

  test("specs, bugs, events, checkpoints, decisions, and the run state are collected", () => {
    const idea = "IDEA-001-demo";
    const spec = `specs/${idea}-Specs/SPEC-001-core`;
    put(`ideation/${idea}/idea-001-demo.md`, "---\ntitle: Demo\nstatus: Handed off\n---\n# Demo\n");
    put(`specs/${idea}-Specs/ROADMAP.md`, "# Roadmap - IDEA-001: Demo\n\n## Execution Plan\n| Order | Spec | Delivery | Depends on | Lane | Est. tokens | Restore point |\n|--|--|--|--|--|--|--|\n| 1 | [[SPEC-001-core/SPEC-001-core]] | Core | None | A | 10k | CP |\n");
    put(`${spec}/SPEC-001-core.md`, "# SPEC-001: Core\n\n| Priority | Category | Status | Wave | Depends on | Blocks | Index |\n|--|--|--|--|--|--|--|\n| P1 | Feature | In Progress | 1 | None | None | [[x]] |\n\n## Delivery Brief\n- **Who:** dev\n\n## Acceptance Criteria\n- [x] AC-1 - works\n\n## Backlog\n| Key | Type | Title | Status | Depends on | Wave | Files | File |\n|--|--|--|--|--|--|--|--|\n| Story-001 | Story | Do it | Ready | None | 1 | 1 | [[Backlog/Story-001-x]] |\n\n## Architecture\nsee ADR-0001\n");
    put(`${spec}/Backlog/Story-001-x.md`, "# Story-001: Do it\n\n| Type | Parent | Priority | Estimate | Status | Dialect | Depends on | Blocks |\n|--|--|--|--|--|--|--|--|\n| Story | [[x]] | P1 | S | Done | backend-go | None | None |\n");
    put(`${spec}/Backlog/Bug-001-x.md`, "# Bug-001: Broken\n\n| Type | Parent | Source | Severity | Status | Story / AC | Regression test | Evidence |\n|--|--|--|--|--|--|--|--|\n| Bug | [[x]] | verifier | blocker | open | Story-001 / AC-1 | T-1 | x |\n");
    put("coordination/backchannel.jsonl", '{"ts":"2026-10-14T09:00:00Z","id":"BC-00001","from":"kcc-run","to":"broadcast","kind":"implement-completed","spec":"SPEC-001","session":null,"payload":{"state":15,"wave":"1"}}\n');
    put("coordination/checkpoints/CP-001.md", "---\nid: CP-001\ncreated: 2026-10-14T10:00:00Z\nreason: manual\n---\n");
    put("coordination/run/run.json", '{"status":"running","state":"15","fasttrack":"1","depthlevel":"2","updated":"2026-10-14T10:00:00Z","specs":"IDEA-001-demo/SPEC-001-core","spec_index":"0"}');
    put("Traces/Session-demo/HumanDecisions.md", "# Human Decisions\n\n## 1. Approve scope for SPEC-001\n\n- **When:** 2026-10-14T09:05:00Z\n- **Human decision:** approve\n");
    const r = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
    expect(r.status).toBe(0);
    const d = pageData();
    expect(d.specs).toHaveLength(1);
    const s = d.specs[0];
    expect(s.id).toBe("SPEC-001");
    expect(s.status).toBe("In Progress");
    expect(s.items[0].status).toBe("Done"); // the item file wins over the spec table
    expect(s.bugs[0].severity).toBe("blocker");
    expect(s.adrRefs).toEqual(["ADR-0001"]);
    expect(d.roadmaps[0].rows[0].spec).toContain("SPEC-001");
    expect(d.events[0].ts).toBe("2026-10-14T09:00:00Z"); // ISO text is kept, not turned into a locale date
    expect(d.events[0].spec).toBe("SPEC-001");
    expect(d.checkpoints[0].id).toBe("CP-001");
    expect(d.run.fasttrack).toBe(true);
    expect(d.run.currentSpec).toBe("SPEC-001");
    expect(d.humanDecisions[0].decision).toBe("approve");
    expect(d.states.some((x: any) => x.name === "ROI")).toBe(false); // a fast-track run uses the fast-track table, which has no ROI state
    expect(d.states.map((x: any) => x.id)).toEqual([0, 1, 4, 5, 6, 9, 14, 15, 19, 16, 17, 18]);
    expect(existsSync(join(root, "dashboard", "index.html"))).toBe(true);
  });
});

describe("agent history", () => {
  test("sessions and subagents are read from the Claude transcripts with model, effort and tokens", () => {
    const cfg = mkdtempSync(join(tmpdir(), "kcc-claude-"));
    try {
      const real = realpathSync.native(root);
      const proj = join(cfg, "projects", real.replace(/[^A-Za-z0-9]/g, "-"));
      const asst = (id: string, model: string, ts: string, input: number, output: number, cr: number, cw: number) =>
        JSON.stringify({ type: "assistant", timestamp: ts, effort: "high", message: { id, model, usage: { input_tokens: input, output_tokens: output, cache_read_input_tokens: cr, cache_creation_input_tokens: cw } } });
      const sid = "11111111-2222-3333-4444-555555555555";
      mkdirSync(join(proj, sid, "subagents"), { recursive: true });
      writeFileSync(join(proj, `${sid}.jsonl`), [
        JSON.stringify({ type: "user", timestamp: "2026-10-14T09:00:00.000Z", message: { content: "KCC run state 15 IMPLEMENT for SPEC-001 wave 2. Do only this state." } }),
        asst("msg_a", "claude-sonnet-5", "2026-10-14T09:00:10.000Z", 10, 100, 1000, 50),
        asst("msg_a", "claude-sonnet-5", "2026-10-14T09:00:11.000Z", 10, 100, 1000, 50), // same message logged twice: counted once
        JSON.stringify({ type: "cost-state", totalCostUSD: 0.5 }),
        asst("msg_b", "claude-sonnet-5", "2026-10-14T09:05:00.000Z", 5, 20, 500, 0),
      ].join("\n") + "\n");
      writeFileSync(join(proj, sid, "subagents", "agent-abc.jsonl"), [asst("msg_c", "claude-haiku-4-5-20251001", "2026-10-14T09:01:00.000Z", 7, 300, 2000, 100), asst("msg_d", "claude-haiku-4-5-20251001", "2026-10-14T09:03:00.000Z", 3, 200, 1000, 0)].join("\n") + "\n");
      writeFileSync(join(proj, sid, "subagents", "agent-abc.meta.json"), JSON.stringify({ agentType: "implementer", description: "Implement SPEC-001 wave 2" }));
      put(".claude/agents/implementer.md", "---\nname: implementer\nmodel: haiku\neffort: medium\n---\nx\n");
      const r = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true, env: { CLAUDE_CONFIG_DIR: cfg } });
      expect(r.status).toBe(0);
      const d = pageData();
      const session = d.agents.find((a: any) => a.kind === "session");
      const sub = d.agents.find((a: any) => a.kind === "subagent");
      expect(session.stateName).toBe("IMPLEMENT");
      expect(session.spec).toBe("SPEC-001");
      expect(session.wave).toBe("2");
      expect(session.model).toBe("claude-sonnet-5");
      expect(session.tokens).toEqual({ input: 15, output: 120, cacheRead: 1500, cacheWrite: 50 });
      expect(session.costUSD).toBeCloseTo(0.5);
      expect(session.durationMs).toBe(300000);
      expect(sub.agent).toBe("implementer");
      expect(sub.parent).toBe(session.id);
      expect(sub.model).toBe("claude-haiku-4-5-20251001");
      expect(sub.effort).toBe("medium");
      expect(sub.effortSource).toBe("profile");
      expect(sub.tokens).toEqual({ input: 10, output: 500, cacheRead: 3000, cacheWrite: 100 });
      expect(d.profiles.find((p: any) => p.name === "implementer").model).toBe("haiku");
    } finally {
      rmSync(cfg, { recursive: true, force: true });
    }
  });
});

describe("stage timing", () => {
  const tpl = payloadFiles().get("kernel/templates/dashboard.html")!.toString("utf8");
  const src = tpl.split("/*stage-timing:start*/")[1]!.split("/*stage-timing:end*/")[0]!;
  const { stageTimes, fmtHMS } = new Function(`${src}; return { stageTimes, fmtHMS };`)() as {
    stageTimes: (d: any, now: number) => { rows: any[]; totals: any };
    fmtHMS: (ms: number) => string;
  };
  const states = [{ id: 1, name: "IDEA" }, { id: 2, name: "ROI", skipped: true }, { id: 3, name: "TECH" }, { id: 4, name: "SPECIALISTS" }];
  const iso = (m: number, s = 0) => `2026-10-14T09:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}Z`;
  const t = (m: number, s = 0) => Date.parse(iso(m, s));

  test("formats HH:MM:SS", () => {
    expect(fmtHMS(0)).toBe("00:00:00");
    expect(fmtHMS(3661000)).toBe("01:01:01");
    expect(fmtHMS(359999000)).toBe("99:59:59");
  });

  test("agent time is the sum of each dispatch; a finished stage waits on nobody", () => {
    const d = { states, run: { status: "done", state: -1 }, runLogs: [
      { state: 1, started: iso(0), ended: iso(2, 30) },
      { state: 1, started: iso(10), ended: iso(11) }, // a retry adds to the same stage
      { state: 3, started: iso(3), ended: iso(3, 45) },
    ], events: [] };
    const r = stageTimes(d, t(30));
    expect(fmtHMS(r.rows[0].totalMs)).toBe("00:03:30");
    expect(r.rows[0].attempts).toBe(2);
    expect(r.rows[0].dominant).toBe("agent");
    expect(r.rows[0].waiting).toBe("");
    expect(r.rows[1].totalMs).toBe(0); // skipped
    expect(fmtHMS(r.totals.agentMs)).toBe("00:04:15");
    expect(r.totals.humanMs).toBe(0);
  });

  test("a gate adds human time from trigger to answer, and an open gate keeps counting", () => {
    const ev = (kind: string, ts: string, gate_id: string, state: number) => ({ kind, ts, payload: { gate_id, state } });
    const d = { states, run: { status: "paused", state: 4 }, runLogs: [{ state: 4, started: iso(0), ended: iso(1) }], events: [
      ev("human-gate-triggered", iso(5), "G1", 1), ev("human-gate-decision", iso(7, 30), "G1", 1),
      ev("human-gate-triggered", iso(20), "G2", 4),
    ] };
    const r = stageTimes(d, t(26));
    expect(fmtHMS(r.rows[0].humanMs)).toBe("00:02:30");
    expect(r.rows[0].dominant).toBe("human");
    expect(r.rows[3].waiting).toBe("human");
    expect(fmtHMS(r.rows[3].totalMs)).toBe("00:07:00"); // 1m agent + 6m open gate
    expect(fmtHMS(r.totals.humanMs)).toBe("00:08:30");
  });

  test("the running stage ticks on from its dispatch start and is waiting on an agent", () => {
    const d = { states, run: { status: "running", state: 3 }, runLogs: [{ state: 3, started: iso(10), ended: iso(10, 1) }], events: [] };
    const r = stageTimes(d, t(14, 5));
    expect(r.rows[2].waiting).toBe("agent");
    expect(fmtHMS(r.rows[2].totalMs)).toBe("00:04:05");
    expect(r.rows[2].openSince).toBe(t(10));
  });

  test("a stage just dispatched, before its log exists, counts from the run's update time", () => {
    // The page is rebuilt at dispatch, so the log for the stage that is starting is not there yet.
    const d = { states, run: { status: "running", state: 3, updated: iso(10) }, runLogs: [{ state: 1, started: iso(0), ended: iso(2) }], events: [] };
    const r = stageTimes(d, t(10, 42));
    expect(r.rows[2].waiting).toBe("agent");
    expect(r.rows[2].openSince).toBe(t(10));
    expect(fmtHMS(r.rows[2].totalMs)).toBe("00:00:42");
    // a later wave of the same state: earlier waves' time is kept and the new wave counts on top
    const d2 = { states, run: { status: "running", state: 1, updated: iso(20) }, runLogs: [{ state: 1, started: iso(0), ended: iso(2) }], events: [] };
    const r2 = stageTimes(d2, t(20, 30));
    expect(fmtHMS(r2.rows[0].totalMs)).toBe("00:02:30");
    // a log that belongs to the current dispatch is not counted twice
    const d3 = { states, run: { status: "running", state: 3, updated: iso(10) }, runLogs: [{ state: 3, started: iso(10, 1), ended: iso(10, 2) }], events: [] };
    expect(fmtHMS(stageTimes(d3, t(10, 42)).rows[2].totalMs)).toBe("00:00:41");
  });

  test("the generator lists each dispatch with its start and end", () => {
    const dir = join(root, "coordination", "run", "logs");
    mkdirSync(dir, { recursive: true });
    const f = join(dir, "state-15-SPEC-001-w2-1.log");
    writeFileSync(f, "# kcc-run 2026-10-14T09:00:00Z harness claude\n# claude -p x\n");
    utimesSync(f, new Date("2026-10-14T09:04:30Z"), new Date("2026-10-14T09:04:30Z"));
    const r = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
    expect(r.status).toBe(0);
    const log = pageData().runLogs.find((x: any) => x.state === 15);
    expect(log.spec).toBe("SPEC-001");
    expect(log.wave).toBe("2");
    expect(log.attempt).toBe("1");
    expect(log.started).toBe("2026-10-14T09:00:00Z");
    expect(log.ended).toBe("2026-10-14T09:04:30Z");
  });
});
