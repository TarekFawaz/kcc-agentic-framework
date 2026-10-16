import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { applyPayload } from "../src/lock";
import { parsePlanItems, routeAll, securityHit, withRouting } from "../src/run/routing";

// Plan-time routing: model and effort per backlog item, decided once from the plan and read by the drivers.
setDefaultTimeout(120000); // each kcc-route call is a PowerShell or bash process that reads the plan
const root = mkdtempSync(join(tmpdir(), "kcc-routing-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const put = (rel: string, text: string): void => {
  mkdirSync(dirname(join(root, rel)), { recursive: true });
  writeFileSync(join(root, rel), text);
};
const SPEC = "specs/IDEA-001-demo-Specs/SPEC-001-skeleton";
const PLAN = `# Plan

## Backlog Coverage
| Item | Type | Dialect | Complexity | Wave | Plan coverage | Notes |
|--|--|--|--|--|--|--|
| Enabler-001 | Enabler | backend-nodejs | low | 1 | Covered | scaffold |
| Enabler-002 | Enabler | backend-nodejs | medium | 2 | Covered | database and migrations |
| Enabler-003 | Enabler | backend-nodejs | high | 2 | Covered | session cookies and password hashing |
| Story-001 | Story | backend-nodejs | extra-high | 3 | Covered | ledger consistency |
| Story-002 | Story | frontend-react | medium | 3 | Covered | many files |

## Atomic test cases
| Test ID | Item | AC | Level | Description |
|--|--|--|--|--|
| T-001 | Story-001 | AC-1 | unit | x |

## Verification Steps
- npm test
`;

describe("kcc route", () => {
  test("the Backlog Coverage table is read, and security words are found", () => {
    const items = parsePlanItems(PLAN);
    expect(items.map((i) => [i.key, i.complexity, i.wave])).toEqual([["Enabler-001", "low", "1"], ["Enabler-002", "medium", "2"], ["Enabler-003", "high", "2"], ["Story-001", "extra-high", "3"], ["Story-002", "medium", "3"]]);
    expect(securityHit("login with a password")).toBe("password");
    expect(securityHit("show the list of accounts")).toBeUndefined();
  });

  test("each item gets its own model and effort: default, security and high complexity raise effort, extra-high goes xhigh, many files raise effort, nothing passes the cap", () => {
    applyPayload(root);
    put(`${SPEC}/plan.md`, PLAN);
    const many = Array.from({ length: 7 }, (_, i) => `- \`src/IDEA-001-demo/web/f${i}.tsx\``).join("\n");
    put(`${SPEC}/Backlog/Story-002-wide.md`, `# Story-002\n\n## Impacted Files\n${many}\n`);
    put("ideation/IDEA-001-demo/Research.md", "# Research\n\n## Domain\nnovel\n");
    const routed = routeAll(root);
    expect(routed).toHaveLength(1);
    const by = Object.fromEntries(routed[0]!.routes.map((r) => [r.key, r]));
    expect(by["Enabler-001"]).toMatchObject({ tier: "balanced", effort: "high", model: "claude-sonnet-5-5" }); // novel domain: effort high
    expect(by["Enabler-003"]!.why).toContain("security-sensitive (session)");
    expect(by["Enabler-003"]!.effort).toBe("high");
    expect(by["Story-001"]!.effort).toBe("xhigh");
    expect(by["Story-002"]!.why).toContain("large unit");
    for (const r of routed[0]!.routes) expect(r.tier).toBe("balanced"); // novel domain would go strong; implementation is capped
    expect(by["Enabler-001"]!.why).toContain("capped at balanced");
  });

  test("the table is written into plan.md once, before Verification Steps, and a rerun replaces it", () => {
    const file = join(root, SPEC, "plan.md");
    const once = readFileSync(file, "utf8");
    expect(once).toContain("## Routing");
    expect(once.indexOf("## Routing")).toBeLessThan(once.indexOf("## Verification Steps"));
    expect(once).toMatch(/\| Story-001 \| 3 \| balanced \| claude-sonnet-5-5 \| xhigh \|/);
    routeAll(root);
    const twice = readFileSync(file, "utf8");
    expect(twice.match(/## Routing/g)).toHaveLength(1);
    expect(twice).toBe(once);
    expect(withRouting("# P\n", []).match(/## Routing/g)).toHaveLength(1);
  });

  test("--dry-run changes nothing and a missing Backlog Coverage table routes nothing", () => {
    const file = join(root, SPEC, "plan.md");
    const before = readFileSync(file, "utf8");
    expect(routeAll(root, "SPEC-001", true)).toHaveLength(1);
    expect(readFileSync(file, "utf8")).toBe(before);
    put("specs/IDEA-001-demo-Specs/SPEC-002-bare/plan.md", "# Plan\n\nno table\n");
    expect(routeAll(root, "SPEC-002")).toEqual([]);
  });
});


describe("the drivers ask the router (kcc-route) for every dispatch", () => {
  // kcc-run (ps1 and sh) call .KCC/tools/kcc-route, the port of router.ts, with the agent, spec, wave and attempt. Both ports
  // read the same plan above and must agree with each other and with `kcc route`'s table.
  const TAB = String.fromCharCode(9);
  const tools = join(root, ".KCC", "tools");
  const sh = (args: string[]): string[] => spawnSync("bash", [join(tools, "kcc-route.sh"), "--repo-root", root, ...args], { encoding: "utf8" }).stdout.trim().split(TAB);
  const ps = (args: string[]): string[] => spawnSync("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(tools, "kcc-route.ps1"), "-RepoRoot", root, ...args], { encoding: "utf8" }).stdout.trim().split(TAB);

  test("bash: wave 3 (extra-high) is xhigh, wave 2 (security) is high, the whole spec is xhigh; a spec with no plan routes from the profile", () => {
    expect(sh(["--agent", "implementer", "--spec", "SPEC-001", "--wave", "3"]).slice(0, 3)).toEqual(["balanced", "claude-sonnet-5-5", "xhigh"]);
    expect(sh(["--agent", "implementer", "--spec", "SPEC-001", "--wave", "2"])[2]).toBe("high");
    expect(sh(["--agent", "implementer", "--spec", "SPEC-001"])[2]).toBe("xhigh");
    expect(sh(["--agent", "implementer", "--spec", "SPEC-002"]).slice(0, 3)).toEqual(["balanced", "claude-sonnet-5-5", "high"]); // novel domain, no plan rows
    expect(sh(["--agent", "architect"]).slice(0, 3)).toEqual(["balanced", "claude-sonnet-5-5", "high"]);
  });

  test("PowerShell: the same plan gives the same answers", () => {
    if (process.platform !== "win32") return;
    expect(ps(["-Agent", "implementer", "-Spec", "SPEC-001", "-Wave", "3"]).slice(0, 3)).toEqual(["balanced", "claude-sonnet-5-5", "xhigh"]);
    expect(ps(["-Agent", "implementer", "-Spec", "SPEC-001", "-Wave", "2"])[2]).toBe("high");
    expect(ps(["-Agent", "implementer", "-Spec", "SPEC-001"])[2]).toBe("xhigh");
    expect(ps(["-Agent", "architect"]).slice(0, 3)).toEqual(["balanced", "claude-sonnet-5-5", "high"]);
  });

  test("a verifier retry is routed like its first run, and the caller's ceilings cap tier and effort, in both ports", () => {
    const first = sh(["--agent", "verifier", "--spec", "SPEC-001"]);
    const retry = sh(["--agent", "verifier", "--spec", "SPEC-001", "--attempt", "2"]);
    expect(retry.slice(0, 3)).toEqual(first.slice(0, 3));
    expect(retry[3]).not.toContain("attempt");
    expect(sh(["--agent", "implementer", "--spec", "SPEC-001", "--wave", "1", "--attempt", "2"])[3]).toContain("attempt 2"); // fixers still escalate
    // SPEC-002 has no plan rows and a novel domain: the verifier goes strong; REVIEW and a scoped re-verification are capped by kcc-run
    const novel = sh(["--agent", "verifier", "--spec", "SPEC-002"]);
    expect(novel[0]).toBe("strong");
    const capped = sh(["--agent", "verifier", "--spec", "SPEC-002", "--attempt", "2", "--max-tier", "balanced", "--max-effort", "high"]);
    expect(capped.slice(0, 3)).toEqual(["balanced", "claude-sonnet-5-5", "high"]);
    if (process.platform === "win32") {
      expect(ps(["-Agent", "verifier", "-Spec", "SPEC-001", "-Attempt", "2"]).slice(0, 3)).toEqual(first.slice(0, 3));
      expect(ps(["-Agent", "verifier", "-Spec", "SPEC-002", "-Attempt", "2", "-MaxTier", "balanced", "-MaxEffort", "high"]).slice(0, 3)).toEqual(capped.slice(0, 3));
    }
  });

  test("a retry raises the effort, and another harness gets its own model and a folded effort", () => {
    expect(sh(["--agent", "implementer", "--spec", "SPEC-001", "--wave", "1", "--attempt", "2"])[2]).toBe("xhigh"); // novel: high, retry: +1
    const codex = sh(["--agent", "implementer", "--spec", "SPEC-001", "--wave", "3", "--harness", "codex"]);
    expect(codex.slice(0, 3)).toEqual(["balanced", "gpt-6.1-sol", "high"]); // xhigh folded to codex's high
  });
});
