import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { appendFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { upgrade } from "../src/commands/upgrade";
import { applyPayload, readLock, writeLock } from "../src/lock";
import { payloadFiles, payloadVersion } from "../src/payload";
import { runTool } from "../src/platform";
import { CLI_VERSION } from "../src/version";

// Upgrade path for an existing workspace (plan: model tiers / fasttrack / depthlevel / deep): the user's settings and
// edits survive, new keys arrive, .KCC/model-overrides keeps an earlier tier, and the sync that follows still validates.
setDefaultTimeout(240000);
const root = mkdtempSync(join(tmpdir(), "kcc-upg-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const kcc = (rel: string): string => join(root, ".KCC", rel);
const settings = (): Record<string, any> => JSON.parse(readFileSync(kcc("settings.json"), "utf8"));

async function run(args: string[]): Promise<{ code: number; out: string }> {
  const lines: string[] = [];
  const log = console.log;
  console.log = (...a: unknown[]) => { lines.push(a.join(" ")); };
  try {
    const code = await upgrade(["--dir", root, ...args]);
    return { code, out: lines.join("\n") };
  } finally {
    console.log = log;
  }
}

beforeAll(() => {
  // An earlier install: current files, an older lock version, a settings file from before the new keys,
  // one agent the user edited, and a model-overrides file.
  applyPayload(root);
  const lock = readLock(root)!;
  writeLock(root, { ...lock, payload_version: "0.5.1" });
  writeFileSync(kcc("settings.json"), JSON.stringify({ quality: { coverage_min_pct: 55 }, run: { max_attempts: 7 }, mine: true }, null, 2) + "\n");
  appendFileSync(kcc("capabilities/agents/planner.md"), "\nlocal note\n");
  writeFileSync(kcc("model-overrides"), "# keep the old tier\nimplementer = strong-reasoning high\nbutler = bogus-class\n");
});

describe("upgrade of an existing workspace", () => {
  test("the shipped version is newer than the one the workspace had", () => {
    expect(payloadVersion).toBe(CLI_VERSION);
    expect(payloadVersion).not.toBe("0.5.1");
  });

  test("--dry-run lists what would change and writes nothing", async () => {
    const before = readFileSync(kcc("settings.json"), "utf8");
    const r = await run(["--dry-run"]);
    expect(r.code).toBe(0);
    expect(r.out).toContain("Would upgrade 0.5.1 ->");
    expect(r.out).toMatch(/Would add settings: .*deep/);
    expect(readFileSync(kcc("settings.json"), "utf8")).toBe(before);
    expect(readLock(root)!.payload_version).toBe("0.5.1");
    expect(r.out).not.toContain("Model tiers changed");
  });

  test("upgrade keeps the user's values, adds new keys, reports the edited agent, prints the tier notice once, and syncs", async () => {
    const r = await run([]);
    expect(r.out).toContain("Added settings:");
    expect(r.out).toContain("Model tiers changed");
    expect(r.code).toBe(1); // the edited agent is a conflict
    expect(r.out).toContain("capabilities/agents/planner.md");
    expect(readFileSync(kcc("capabilities/agents/planner.md"), "utf8")).toContain("local note");
    const s = settings();
    expect(s.quality.coverage_min_pct).toBe(55);
    expect(s.run.max_attempts).toBe(7);
    expect(s.mine).toBe(true);
    expect(s.deep).toMatchObject({ enabled: true, max_per_run: 2 });
    expect(s.spec_sizing.max_plan_lines).toBe(250);
    expect(s.run.fasttrack_direct).toBe(true);
    expect(s.notices.model_tiers_v2).toBe(true);
    expect(readLock(root)!.payload_version).toBe(payloadVersion);
  });

  test("model-overrides is honoured by the sync that follows, and a bad class is ignored", () => {
    const agent = (n: string): string => readFileSync(join(root, ".claude", "agents", `${n}.md`), "utf8");
    expect(agent("implementer")).toMatch(/model:\s*claude-opus-5-5/);
    expect(agent("implementer")).toMatch(/effort:\s*high/);
    expect(agent("butler")).not.toContain("bogus");
    expect(agent("butler")).toMatch(/model:\s*claude-haiku-5-5/); // butler keeps its own class
    expect(existsSync(join(root, "coordination", "orchestrator.json"))).toBe(true);
    expect(readFileSync(join(root, "coordination", "orchestrator.md"), "utf8")).toContain("DeepThinking is a human-costed exception");
  });

  test("a second upgrade is quiet: no notice, no new settings", async () => {
    const r = await run(["--no-sync"]);
    expect(r.out).not.toContain("Model tiers changed");
    expect(r.out).not.toContain("Added settings");
    expect(payloadFiles().size).toBeGreaterThan(0);
  });

  test("the upgraded workspace validates", () => {
    const v = runTool(root, "validate-kcc", ["--repo-root", root, "--mode", "cell"], { capture: true });
    expect(v.status).toBe(0);
    expect(v.stdout).toContain("KCC validation passed");
  });
});
