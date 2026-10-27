import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { payloadFiles } from "../src/payload";
import { runTool } from "../src/platform";
import { DEEP_TASKS, deepGate, estimateDeepUsd, route, type DeepRequest, type Registry, type Effort, type Task, type Tier } from "../src/run/router";

const repo = join(import.meta.dir, "..", "..");
const registry = JSON.parse(readFileSync(join(repo, ".KCC", "kernel", "models.json"), "utf8")) as Registry;
const base: DeepRequest = { task: "architecture-tradeoff", agent: "architect", harness: "claude", registry };

describe("DeepThinking (protocols/deep-thinking.md)", () => {
  test("the router never returns a deep tier, whatever the signals", () => {
    const tiers: Tier[] = ["fast", "balanced", "strong"];
    const efforts: Effort[] = ["low", "medium", "high", "xhigh", "max"];
    const tasks: Task[] = ["research", "architecture", "security", "spec", "plan", "review", "implement", "scaffold", "docs", "close", "other"];
    for (const defaultTier of tiers) for (const defaultEffort of efforts) for (const task of tasks)
      for (const domain of ["novel", "common", undefined] as const) for (const attempt of [1, 3]) {
        const r = route({ defaultTier, defaultEffort, task, domain, risk: true, complexity: "extra-high", items: 9, files: 9, attempt });
        expect(["fast", "balanced", "strong"]).toContain(r.tier);
        expect(["low", "medium", "high", "xhigh"]).toContain(r.effort);
      }
  });
  test("the registry carries the deep tier and the catalogue matches the code", () => {
    expect(registry.harnesses.claude?.deep?.id).toBe("claude-fable-5-1");
    expect(registry.harnesses.claude?.deep?.max_effort).toBe("max");
    expect([...(registry.deep_tasks ?? [])].sort()).toEqual(Object.keys(DEEP_TASKS).sort());
    for (const h of ["codex", "opencode", "ollama"]) expect(registry.harnesses[h]?.deep).toBeUndefined();
  });
  test("an interactive run asks the human; nothing is spawned without that", () => {
    expect(deepGate(base)).toMatchObject({ outcome: "ask", fallback: "strong" });
  });
  test("tasks outside the catalogue, or on the wrong agent, are refused", () => {
    expect(deepGate({ ...base, task: "write-the-spec", agent: "spec-writer" }).outcome).toBe("refuse");
    expect(deepGate({ ...base, agent: "implementer" }).reason).toMatch(/belongs to architect/);
    expect(deepGate({ ...base, task: "threat-model", agent: "security-analyst" }).outcome).toBe("ask");
  });
  test("silent runs fall back to strong unless a spend was pre-approved and covers the estimate", () => {
    expect(deepGate({ ...base, silent: true })).toMatchObject({ outcome: "refuse", fallback: "strong" });
    expect(deepGate({ ...base, silent: true, preApprovedUsd: 3, estUsdHigh: 5 }).outcome).toBe("refuse");
    expect(deepGate({ ...base, silent: true, preApprovedUsd: 8, estUsdHigh: 5 }).outcome).toBe("pre-approved");
  });
  test("the orchestrator may propose deep under fast track (the gate still asks); it can never start human-directed", () => {
    expect(deepGate({ ...base, silent: false }).outcome).toBe("ask");
    expect(deepGate({ ...base, task: "human-directed", agent: "architect" })).toMatchObject({ outcome: "refuse", reason: expect.stringMatching(/only be started by the human/) });
  });
  test("a human starting /deep always gets the cost question: any task, no run cap, no budget floor, never silent-refused", () => {
    const h: DeepRequest = { ...base, initiator: "human", approvedSoFar: 5, budgetLeftPct: 3, silent: true };
    expect(deepGate(h)).toMatchObject({ outcome: "ask", fallback: "none" });
    expect(deepGate({ ...h, task: "human-directed", agent: "verifier" }).outcome).toBe("ask");
    expect(deepGate({ ...h, task: "not-a-task" }).outcome).toBe("refuse");
    expect(deepGate({ ...h, enabled: false }).outcome).toBe("refuse");
    expect(deepGate({ ...h, harness: "ollama" }).outcome).toBe("refuse");
  });
  test("the per-run cap, low budget, disabled mode and harnesses without a deep tier refuse the orchestrator", () => {
    expect(deepGate({ ...base, approvedSoFar: 2 }).outcome).toBe("refuse");
    expect(deepGate({ ...base, approvedSoFar: 1, maxPerRun: 3 }).outcome).toBe("ask");
    expect(deepGate({ ...base, budgetLeftPct: 15 }).outcome).toBe("refuse");
    expect(deepGate({ ...base, enabled: false }).outcome).toBe("refuse");
    expect(deepGate({ ...base, harness: "codex" }).reason).toMatch(/no deep tier/);
  });
  test("the cost estimate is a floor of $0.80 plus output and input", () => {
    expect(estimateDeepUsd(0)).toBe(0.8);
    expect(estimateDeepUsd(20000)).toBe(1.76);
    expect(estimateDeepUsd(50000, 100000)).toBe(5.2);
  });
});

describe("check-run-conformance -Scope deep (ps1 and sh twins)", () => {
  setDefaultTimeout(120000);
  const root = mkdtempSync(join(tmpdir(), "kcc-deep-"));
  afterAll(() => rmSync(root, { recursive: true, force: true }));
  const ev = (kind: string, agent = "", task = "", initiator = ""): string => JSON.stringify({ kind, payload: agent ? { agent, task, ...(initiator ? { initiator } : {}) } : {} });
  const run = (events: string[]): { ids: string[]; errors: number } => {
    applyPayload(root);
    mkdirSync(join(root, "coordination"), { recursive: true });
    writeFileSync(join(root, "coordination", "backchannel.jsonl"), events.join(String.fromCharCode(10)) + String.fromCharCode(10));
    const r = runTool(root, "check-run-conformance", ["--scope", "deep", "--repo-root", root, "--json"], { capture: true });
    const ids = [...r.stdout.matchAll(/"id"\s*:\s*"(DEEP-\d+)"/g)].map((m) => m[1]!);
    return { ids, errors: +(/"errors"\s*:\s*(\d+)/.exec(r.stdout)?.[1] ?? -1) };
  };
  test("an approved spawn of a catalogue task passes", () => {
    const r = run([ev("auto-policy-parsed"), ev("deep-approved", "architect", "architecture-tradeoff"), ev("deep-spawned", "architect", "architecture-tradeoff")]);
    expect(r).toEqual({ ids: [], errors: 0 });
  });
  test("a spawn with no approval, a task outside the catalogue and a third spawn are each an error", () => {
    const r = run([
      ev("auto-policy-parsed"),
      ev("deep-spawned", "architect", "architecture-tradeoff"),
      ev("deep-approved", "security-analyst", "threat-model"), ev("deep-spawned", "security-analyst", "threat-model"),
      ev("deep-approved", "architect", "write-spec"), ev("deep-spawned", "architect", "write-spec"),
    ]);
    expect(r.ids.sort()).toEqual(["DEEP-001", "DEEP-002", "DEEP-003"]);
  });
  test("an approval is used once, and an earlier run does not count against this one", () => {
    const twice = run([ev("auto-policy-parsed"), ev("deep-approved", "architect", "architecture-tradeoff"), ev("deep-spawned", "architect", "architecture-tradeoff"), ev("deep-spawned", "architect", "architecture-tradeoff")]);
    expect(twice.ids).toEqual(["DEEP-001"]);
    const fresh = run([ev("deep-spawned", "architect", "architecture-tradeoff"), ev("auto-policy-parsed"), ev("deep-approved", "architect", "architecture-tradeoff"), ev("deep-spawned", "architect", "architecture-tradeoff")]);
    expect(fresh).toEqual({ ids: [], errors: 0 });
  });
  test("a human's /deep needs an approval too, but is not counted against the run cap", () => {
    const h = (a: string, t: string): string[] => [ev("deep-approved", a, t, "human"), ev("deep-spawned", a, t, "human")];
    const many = run([ev("auto-policy-parsed"), ...h("architect", "human-directed"), ...h("architect", "human-directed"), ...h("verifier", "human-directed"), ...h("architect", "architecture-tradeoff")]);
    expect(many).toEqual({ ids: [], errors: 0 });
    const unapproved = run([ev("auto-policy-parsed"), ev("deep-spawned", "architect", "human-directed", "human")]);
    expect(unapproved.ids).toEqual(["DEEP-001"]);
  });
  test("the payload ships the protocol, the /deep skill and the orchestrator rule", () => {
    expect(payloadFiles().has("kernel/protocols/deep-thinking.md")).toBe(true);
    expect(payloadFiles().get("capabilities/skills/deep.md")!.toString("utf8")).toContain("name: deep");
    expect(payloadFiles().get("kernel/templates/orchestrator.md")!.toString("utf8")).toContain("DeepThinking is a human-costed exception");
  });
});
