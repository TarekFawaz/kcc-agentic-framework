import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { loadRegistry, modelFor, readDomain, route, RETRY_RULES } from "../src/run/router";
import { payloadFiles } from "../src/payload";

const root = mkdtempSync(join(tmpdir(), "kcc-router-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

describe("model router (model-routing.md)", () => {
  test("no signal, no move", () => {
    // even a default pick states its starting point (the dashboard shows the reasons verbatim)
    expect(route({ defaultTier: "fast", defaultEffort: "medium", task: "implement" })).toEqual({ tier: "fast", effort: "medium", reasons: ["agent default: fast / medium"] });
  });
  test("a common CRUD wave stays on the executor tier; an auth module goes balanced/high", () => {
    expect(route({ defaultTier: "fast", defaultEffort: "medium", task: "implement", domain: "common" }).tier).toBe("fast");
    const r = route({ defaultTier: "fast", defaultEffort: "medium", task: "implement", risk: true });
    expect(r.tier).toBe("balanced");
    expect(r.effort).toBe("high");
  });
  test("a spec-writer and a planner on a common domain stay on balanced (round 11: Haiku skipped plan.md); docs and scaffold still step down; on a novel domain the architect goes strong/high", () => {
    expect(route({ defaultTier: "balanced", defaultEffort: "high", task: "spec", domain: "common" })).toEqual({ tier: "balanced", effort: "high", reasons: ["agent default: balanced / high"] });
    expect(route({ defaultTier: "balanced", defaultEffort: "high", task: "plan", domain: "common" })).toMatchObject({ tier: "balanced", effort: "high" });
    expect(route({ defaultTier: "balanced", defaultEffort: "medium", task: "docs", domain: "common" }).tier).toBe("fast");
    expect(route({ defaultTier: "balanced", defaultEffort: "medium", task: "scaffold", domain: "common" }).tier).toBe("fast");
    const a = route({ defaultTier: "balanced", defaultEffort: "medium", task: "architecture", domain: "novel" });
    expect(a).toMatchObject({ tier: "strong", effort: "high" });
  });
  test("research, architecture, security, spec and plan never run below balanced, whatever the domain says", () => {
    expect(route({ defaultTier: "fast", defaultEffort: "low", task: "security" }).tier).toBe("balanced");
    for (const task of ["research", "architecture", "security", "spec", "plan"] as const) {
      for (const domain of [undefined, "common", "specialised", "novel"] as const) {
        const r = route({ defaultTier: "fast", defaultEffort: "low", task, domain });
        expect(r.tier).not.toBe("fast");
        expect(r.reasons).toContain(`${task} never runs below balanced: tier raised`);
      }
    }
  });
  test("a planning retry (spec, plan) keeps the tier and raises the effort to at most high, never xhigh or Opus; an implementer retry still escalates", () => {
    const base = { defaultTier: "balanced", defaultEffort: "high", domain: "common" } as const;
    for (const task of ["spec", "plan"] as const) {
      for (const attempt of [2, 3]) {
        const r = route({ ...base, task, attempt });
        expect(r.tier).toBe("balanced");
        expect(r.effort).toBe("high");
        expect(r.reasons).toEqual(["agent default: balanced / high", `attempt ${attempt}: effort stays high, tier unchanged for planning`]);
      }
      const m = route({ ...base, defaultEffort: "medium", task, attempt: 2 });
      expect(m).toMatchObject({ tier: "balanced", effort: "high" });
      expect(m.reasons).toContain("attempt 2: effort raised to high, tier unchanged for planning");
      expect(route({ ...base, defaultEffort: "low", task, attempt: 2 }).effort).toBe("medium"); // one step, still below the ceiling
      // a first run that is already above the ceiling (extra-high complexity) is not lowered by the retry
      expect(route({ ...base, task, attempt: 2, complexity: "extra-high" })).toMatchObject({ tier: "balanced", effort: "xhigh" });
    }
    expect(route({ ...base, task: "implement", attempt: 2 })).toMatchObject({ tier: "strong", effort: "xhigh" });
    expect(RETRY_RULES.spec).toEqual({ tier: false, effortCeiling: "high" });
    expect(RETRY_RULES.plan).toEqual({ tier: false, effortCeiling: "high" });
    expect(RETRY_RULES.review).toBeNull();
  });
  test("every reasons list starts with the agent default, names each adjustment with its cause, and stays short", () => {
    expect(route({ defaultTier: "balanced", defaultEffort: "high", task: "plan" }).reasons).toEqual(["agent default: balanced / high"]);
    expect(route({ defaultTier: "balanced", defaultEffort: "max", task: "plan" }).reasons[0]).toBe("agent default: balanced / xhigh");
    const r = route({ defaultTier: "balanced", defaultEffort: "medium", task: "implement", risk: true, riskCause: "security-sensitive (auth)", files: 6, attempt: 2, maxTier: "balanced" });
    expect(r.reasons).toEqual([
      "agent default: balanced / medium",
      "security-sensitive (auth): effort high",
      "large unit: effort up",
      "attempt 2: tier up, effort unchanged", // risk gave high, the large unit gave xhigh, which is the ceiling
      "capped at balanced for implement",
    ]);
    expect(r.reasons.join("; ").length).toBeLessThan(170);
    expect(route({ defaultTier: "fast", defaultEffort: "medium", task: "implement", risk: true }).reasons).toContain("CR-7 risk: effort high, tier raised to balanced");
    expect(route({ defaultTier: "balanced", defaultEffort: "high", task: "review", risk: true, files: 6, attempt: 2, maxTier: "balanced", maxEffort: "high" }).reasons.join("; ")).toBe(
      "agent default: balanced / high; CR-7 risk: effort high; large unit: effort up; effort capped at high for review");
    expect(route({ defaultTier: "balanced", defaultEffort: "high", task: "plan", domain: "common", attempt: 2 }).reasons.join("; ").length).toBeLessThan(160);
    expect(route({ defaultTier: "balanced", defaultEffort: "high", task: "plan", budgetLeftPct: 10 }).reasons).toContain("budget under 20%: tier capped at balanced");
  });
  test("a retry moves one tier up and one effort up; the move is clamped to default +/- 1", () => {
    const r = route({ defaultTier: "fast", defaultEffort: "medium", task: "implement", attempt: 2 });
    expect(r).toMatchObject({ tier: "balanced", effort: "high" });
    const r2 = route({ defaultTier: "fast", defaultEffort: "medium", task: "implement", attempt: 3, domain: "novel" });
    expect(r2.tier).toBe("balanced"); // fast +1 at most
  });
  test("a verifier or critic is never escalated for a retry (round 10: Opus at xhigh on the second full pass); a first pass keeps its signals", () => {
    const first = route({ defaultTier: "balanced", defaultEffort: "high", task: "review", risk: true, files: 6 });
    expect(first).toMatchObject({ tier: "balanced", effort: "xhigh" }); // a security-sensitive large spec, first pass: unchanged
    for (const attempt of [2, 3]) {
      const r = route({ defaultTier: "balanced", defaultEffort: "high", task: "review", attempt });
      expect(r).toEqual({ tier: "balanced", effort: "high", reasons: ["agent default: balanced / high"] });
      expect(route({ defaultTier: "balanced", defaultEffort: "high", task: "review", risk: true, files: 6, attempt })).toEqual(first);
    }
    expect(route({ defaultTier: "balanced", defaultEffort: "high", task: "implement", attempt: 2 })).toMatchObject({ tier: "strong", effort: "xhigh" }); // fixers still escalate
  });
  test("a caller ceiling caps the effort too (REVIEW and a scoped re-verification: balanced / high)", () => {
    const r = route({ defaultTier: "balanced", defaultEffort: "high", task: "review", domain: "novel", risk: true, files: 6, maxTier: "balanced", maxEffort: "high" });
    expect(r.tier).toBe("balanced");
    expect(r.effort).toBe("high");
    expect(r.reasons).toEqual(expect.arrayContaining(["capped at balanced for review", "effort capped at high for review"]));
    expect(route({ defaultTier: "balanced", defaultEffort: "medium", task: "review", maxEffort: "high" }).reasons).toEqual(["agent default: balanced / medium"]); // no cap reason when nothing is above it
  });
  test("a large unit raises effort; a low budget caps the tier unless there is risk", () => {
    expect(route({ defaultTier: "balanced", defaultEffort: "medium", task: "plan", items: 5 }).effort).toBe("high");
    expect(route({ defaultTier: "strong", defaultEffort: "high", task: "architecture", budgetLeftPct: 10 }).tier).toBe("balanced");
    expect(route({ defaultTier: "strong", defaultEffort: "high", task: "architecture", budgetLeftPct: 10, risk: true }).tier).toBe("strong");
  });
  test("the registry resolves a tier to a pinned id, and the domain is read from Research.md", () => {
    applyPayload(root);
    const reg = loadRegistry(root)!;
    expect(modelFor(reg, "claude", "fast")).toBe("claude-haiku-5-5");
    expect(reg.class_to_tier["fast-implementation"]).toBe("fast");
    mkdirSync(join(root, "ideation", "IDEA-001-x"), { recursive: true });
    writeFileSync(join(root, "ideation", "IDEA-001-x", "Research.md"), "# R\n## Domain\nnovel\n");
    expect(readDomain(root, "IDEA-001-x")).toBe("novel");
    writeFileSync(join(root, "ideation", "IDEA-001-x", "Research.md"), "# R\n## Domain: common\n");
    expect(readDomain(root, "IDEA-001-x")).toBe("common");
  });
  test("the registry and the adapter model map agree", () => {
    const reg = JSON.parse(payloadFiles().get("kernel/models.json")!.toString("utf8"));
    const sync = payloadFiles().get("tools/sync-adapters.ps1")!.toString("utf8");
    for (const [cls, tier] of Object.entries(reg.class_to_tier as Record<string, string>)) {
      expect(sync).toContain(`'${cls}'`);
      expect(sync).toContain(`= '${reg.harnesses.claude[tier].id}'`);
      expect(sync).toContain(`= '${reg.harnesses.codex[tier].id}'`);
    }
  });
});
