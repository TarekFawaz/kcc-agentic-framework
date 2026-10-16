import { afterAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { applyPayload } from "../src/lock";
import { parsePlanItems, routeAll, securityHit, withRouting } from "../src/run/routing";

// Plan-time routing: model and effort per backlog item, decided once from the plan and read by the drivers.
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


describe("the drivers read the routing table", () => {
  // kcc-run (ps1 and sh) only reads `## Routing`. Each driver's reader is lifted out of the script and run on the plan above.
  const TAB = String.fromCharCode(9);
  const planDir = (): string => join(root, SPEC);
  const tools = (n: string): string => readFileSync(join(root, ".KCC", "tools", n), "utf8");

  test("bash: the strongest row of a wave's items wins; with no wave, the strongest of the spec; no table, nothing", () => {
    const src = tools("kcc-run.sh");
    const fn = src.slice(src.indexOf("plan_routing() {"), src.indexOf("agent_mode() {"));
    const script = `spec_dir() { printf '%s' "$SPEC_DIR"; }${String.fromCharCode(10)}${fn}${String.fromCharCode(10)}plan_routing "$1" "$2"`;
    const run = (wave: string, dir = planDir()): string =>
      spawnSync("bash", ["-c", script, "x", "e", wave], { encoding: "utf8", env: { ...process.env, SPEC_DIR: dir.split(String.fromCharCode(92)).join("/") } }).stdout.trim();
    expect(run("3").startsWith(["claude-sonnet-5-5", "xhigh", "balanced"].join(TAB))).toBe(true); // Story-001 is extra-high
    expect(run("2").split(TAB)[1]).toBe("high"); // Enabler-003 is security-sensitive
    expect(run("").split(TAB)[1]).toBe("xhigh"); // the whole spec
    expect(run("9")).toBe("");
    put("specs/IDEA-001-demo-Specs/SPEC-009-none/plan.md", "# Plan");
    expect(run("1", join(root, "specs", "IDEA-001-demo-Specs", "SPEC-009-none"))).toBe("");
  });

  test("PowerShell: the same plan gives the same answers", () => {
    if (process.platform !== "win32") return;
    const src = tools("kcc-run.ps1");
    const fn = src.slice(src.indexOf("function Get-PlanRouting"), src.indexOf("function Get-AgentMode"));
    const script = `function Get-SpecDir($e) { $env:SPEC_DIR }; function Read-Lines($p) { [System.IO.File]::ReadAllLines($p) }; ${fn}; $r = Get-PlanRouting 'e' $args[0]; if ($r) { ($r.model, $r.effort, $r.tier) -join ' ' }`;
    const run = (wave: string): string =>
      spawnSync("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", `& { ${script} } '${wave}'`], { encoding: "utf8", env: { ...process.env, SPEC_DIR: planDir() } }).stdout.trim();
    expect(run("3")).toBe("claude-sonnet-5-5 xhigh balanced");
    expect(run("2").split(" ")[1]).toBe("high");
    expect(run("").split(" ")[1]).toBe("xhigh");
    expect(run("9")).toBe("");
  });
});
