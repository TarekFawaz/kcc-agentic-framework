import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { runTool } from "../src/platform";

// Test round 5: a chat-driven `auto` run writes events but no driver `state`, and the pipeline sat on REPO.
setDefaultTimeout(120000);
const root = mkdtempSync(join(tmpdir(), "kcc-dash-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

describe("dashboard stage of a chat-driven run", () => {
  test("the stage is derived from backchannel events when run.json has no state", () => {
    applyPayload(root);
    mkdirSync(join(root, "coordination", "run"), { recursive: true });
    writeFileSync(join(root, "coordination", "run", "run.json"), JSON.stringify({ scenario: "S2", fasttrack: "1", idea: "IDEA-001" }));
    const ev = (id: number, kind: string, from: string) => JSON.stringify({ ts: "2026-10-15T18:00:00Z", id: `BC-0000${id}`, from, to: "broadcast", kind, spec: "IDEA-001", session: null, payload: {} });
    writeFileSync(join(root, "coordination", "backchannel.jsonl"), [
      ev(1, "auto-policy-parsed", "orchestrator"), ev(2, "idea-interrogation-completed", "idea-interrogator"),
      ev(3, "specialist-brief-created", "technical-interrogator"), ev(4, "specialist-brief-created", "security"),
    ].join("\n") + "\n");
    const r = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
    expect(r.status).toBe(0);
    const html = readFileSync(join(root, "dashboard", "index.html"), "utf8");
    const run = JSON.parse(/"run":(\{[^}]*\})/.exec(html)![1]!);
    expect(run.state).toBe(5); // fast-track table: the briefs are done, ASK is next
    expect(run.status).toBe("idle"); // the events are hours old and no agent wrote anything since
  });

  test("after SPECS the pipeline shows the earliest stage any spec is in; a spec-less event moves nothing", () => {
    const ev = (id: number, kind: string, from: string, spec: string | null) => JSON.stringify({ ts: "2026-10-15T19:00:00Z", id: `BC-000${10 + id}`, from, to: "broadcast", kind, spec, session: null, payload: {} });
    const lines = readFileSync(join(root, "coordination", "backchannel.jsonl"), "utf8").trim().split(String.fromCharCode(10));
    lines.push(ev(1, "architecture-pass-complete", "architect", "IDEA-001"), ev(2, "spec-created", "spec-writer", "SPEC-001"), ev(3, "spec-created", "spec-writer", "SPEC-002"),
      ev(4, "roadmap-created", "spec-writer", "IDEA-001"), ev(5, "toolchain-preflight-result", "orchestrator", null), ev(6, "plan-created", "planner", "SPEC-001"),
      ev(7, "implement-started", "orchestrator", "SPEC-001"));
    writeFileSync(join(root, "coordination", "backchannel.jsonl"), lines.join(String.fromCharCode(10)) + String.fromCharCode(10));
    expect(runTool(root, "build-dashboard", ["--repo-root", root], { capture: true }).status).toBe(0);
    const html = readFileSync(join(root, "dashboard", "index.html"), "utf8");
    const run = JSON.parse(/"run":(\{[^}]*\})/.exec(html)![1]!);
    expect(run.state).toBe(11); // fast-track table: SPEC-001 is implementing; SPEC-002 is written (WRITE, 10) and waits at PLAN
  });
});

describe("dashboard during the lane phase", () => {
  // Rounds 8 and 9: the driver stopped at --until 9 and run.json said "stopped at PREFLIGHT" while a lane built SPEC-001.
  test("each kcc lane reports its own stage, and the page treats a stopped run with a live lane as running", () => {
    const r = mkdtempSync(join(tmpdir(), "kcc-dash-lane-"));
    try {
      applyPayload(r);
      mkdirSync(join(r, "coordination", "run"), { recursive: true });
      writeFileSync(join(r, "coordination", "run", "run.json"), JSON.stringify({ status: "stopped", reason: "until 9", state: "14", scenario: "S2", fasttrack: "1" }));
      const lane = join(r, ".kcc-lanes", "SPEC-001");
      mkdirSync(join(lane, "coordination", "run"), { recursive: true });
      mkdirSync(join(lane, "src"), { recursive: true });
      writeFileSync(join(lane, "src", "a.ts"), "export {};");
      writeFileSync(join(lane, "coordination", "run", "run.json"), JSON.stringify({ status: "running", state: "15", wave: "1" }));
      expect(runTool(r, "build-dashboard", ["--repo-root", r], { capture: true }).status).toBe(0);
      const html = readFileSync(join(r, "dashboard", "index.html"), "utf8");
      const data = JSON.parse(/<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/.exec(html)![1]!);
      expect(data.lanes[0]).toMatchObject({ spec: "SPEC-001", runState: "15", runWave: "1", runStatus: "running" });
      expect(html).toContain("specs running in lanes: ");
    } finally {
      rmSync(r, { recursive: true, force: true });
    }
  });
  test("building the page inside a lane also rebuilds the workspace's page, so lane work reaches it without the scheduler", () => {
    const r = mkdtempSync(join(tmpdir(), "kcc-dash-parent-"));
    try {
      applyPayload(r);
      mkdirSync(join(r, "coordination"), { recursive: true });
      writeFileSync(join(r, "coordination", "lanes.json"), JSON.stringify({ "SPEC-001": { status: "running", dir: "x" } }));
      const lane = join(r, ".kcc-lanes", "SPEC-001");
      applyPayload(lane);
      mkdirSync(join(lane, "coordination", "run"), { recursive: true });
      writeFileSync(join(lane, "coordination", "run", "run.json"), JSON.stringify({ status: "running", state: "15", wave: "1" }));
      expect(existsSync(join(r, "dashboard", "index.html"))).toBe(false);
      expect(runTool(lane, "build-dashboard", ["--repo-root", lane], { capture: true }).status).toBe(0);
      expect(existsSync(join(lane, "dashboard", "index.html"))).toBe(true);
      expect(existsSync(join(r, "dashboard", "index.html"))).toBe(true);
    } finally {
      rmSync(r, { recursive: true, force: true });
    }
  });
});

