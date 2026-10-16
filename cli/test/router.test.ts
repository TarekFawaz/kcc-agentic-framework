import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { loadRegistry, modelFor, readDomain, route } from "../src/run/router";
import { payloadFiles } from "../src/payload";

const root = mkdtempSync(join(tmpdir(), "kcc-router-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

describe("model router (model-routing.md)", () => {
  test("no signal, no move", () => {
    expect(route({ defaultTier: "fast", defaultEffort: "medium", task: "implement" })).toEqual({ tier: "fast", effort: "medium", reasons: [] });
  });
  test("a common CRUD wave stays on the executor tier; an auth module goes balanced/high", () => {
    expect(route({ defaultTier: "fast", defaultEffort: "medium", task: "implement", domain: "common" }).tier).toBe("fast");
    const r = route({ defaultTier: "fast", defaultEffort: "medium", task: "implement", risk: true });
    expect(r.tier).toBe("balanced");
    expect(r.effort).toBe("high");
  });
  test("a spec-writer on a common domain writes on the fast tier; on a novel domain the architect goes strong/high", () => {
    expect(route({ defaultTier: "balanced", defaultEffort: "high", task: "spec", domain: "common" }).tier).toBe("fast");
    const a = route({ defaultTier: "balanced", defaultEffort: "medium", task: "architecture", domain: "novel" });
    expect(a).toMatchObject({ tier: "strong", effort: "high" });
  });
  test("research, architecture and security never run below balanced", () => {
    expect(route({ defaultTier: "fast", defaultEffort: "low", task: "security" }).tier).toBe("balanced");
  });
  test("a retry moves one tier up and one effort up; the move is clamped to default +/- 1", () => {
    const r = route({ defaultTier: "fast", defaultEffort: "medium", task: "implement", attempt: 2 });
    expect(r).toMatchObject({ tier: "balanced", effort: "high" });
    const r2 = route({ defaultTier: "fast", defaultEffort: "medium", task: "implement", attempt: 3, domain: "novel" });
    expect(r2.tier).toBe("balanced"); // fast +1 at most
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
