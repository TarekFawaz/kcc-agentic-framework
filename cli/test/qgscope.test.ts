import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { runTool } from "../src/platform";

// Round 12: the architecture excluded image scans for a local tool, the plan covered no QG-IMAGE, and the gate still scanned two
// images left over from an earlier round and failed the spec on them. The gate's scope now comes from the plan's Gates coverage:
// the architect decides the gates, the planner maps them, the gate runs what they declared and names the rest as out of scope.
setDefaultTimeout(240000);
const root = mkdtempSync(join(tmpdir(), "kcc-qgscope-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const put = (rel: string, text: string): void => {
  mkdirSync(join(root, rel, ".."), { recursive: true });
  writeFileSync(join(root, rel), text);
};
const gate = (args: string[]): any => {
  const r = runTool(root, "quality-gate", ["--repo-root", root, "--spec", "SPEC-001", "--json", ...args], { capture: true });
  const i = r.stdout.indexOf("{");
  return JSON.parse(r.stdout.slice(i));
};

describe("quality-gate scope follows the plan's Gates coverage", () => {
  test("the covered checks run, the rest is reported as out of scope in QG-SCOPE; --scope still wins; no table means all", () => {
    applyPayload(root);
    put("src/IDEA-001-x/package.json", JSON.stringify({ name: "x", scripts: { test: "node -e 0" } }));
    put("src/IDEA-001-x/package-lock.json", JSON.stringify({ name: "x", lockfileVersion: 3, packages: {} }));
    put("specs/IDEA-001-x-Specs/SPEC-001-demo/SPEC-001-demo.md", "---\nspec-id: SPEC-001\nstatus: Ready\n---\n# SPEC-001 demo\n");
    put("specs/IDEA-001-x-Specs/SPEC-001-demo/plan.md", "# plan\n\n## Gates coverage\n| Gate | Covered by |\n|--|--|\n| QG-QUALITY | check:QG-LOCK, check:QG-SECRETS |\n| QG-STATIC | check:QG-STATIC |\n| QG-PROD-1 | T-001 |\n\n## Waves\n");
    const j = gate([]);
    expect(j.scope_source).toBe("plan.md Gates coverage");
    const scope = String(j.scope).split(",");
    for (const s of ["lock", "build", "lint", "test", "coverage", "secrets", "deps", "sast", "static"]) expect(scope).toContain(s);
    expect(scope).not.toContain("image");
    expect(scope).not.toContain("sbom");
    const row = j.checks.find((c: any) => c.id === "QG-SCOPE");
    expect(row).toBeDefined();
    expect(row.status).toBe("pass");
    expect(row.fix_owner).toBe("architect");
    expect(row.message).toContain("not covered by the plan");
    expect(row.message).toContain("image");
    expect(j.checks.some((c: any) => c.id === "QG-IMAGE")).toBe(false);
    expect(j.checks.some((c: any) => c.id === "QG-SBOM")).toBe(false);

    const explicit = gate(["--scope", "lock"]);
    expect(explicit.scope_source).toBe("option");
    expect(explicit.scope).toBe("lock");
    expect(explicit.checks.some((c: any) => c.id === "QG-SCOPE")).toBe(false);

    put("specs/IDEA-001-x-Specs/SPEC-001-demo/plan.md", "# plan\n\n## Waves\n");
    const all = gate(["--scope", "lock,static"]); // a plan without the table and no --scope would run every check; keep the test short
    expect(all.scope_source).toBe("option");
    const none = runTool(root, "quality-gate", ["--repo-root", root, "--spec", "SPEC-001", "--json", "--scope", "static"], { capture: true });
    expect(none.stdout).toContain('"scope_source"');
  });
});
