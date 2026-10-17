import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { applyPayload } from "../src/lock";
import { runTool } from "../src/platform";

// Test round 5 produced 15 specs for a small app and no runnable output after hours. Fast track now has a spec
// budget the human approves, and every spec must carry a status.
setDefaultTimeout(120000);
const root = mkdtempSync(join(tmpdir(), "kcc-budget-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const NL = String.fromCharCode(10);
const put = (rel: string, text: string): void => {
  mkdirSync(dirname(join(root, rel)), { recursive: true });
  writeFileSync(join(root, rel), text);
};
const G = "specs/IDEA-001-demo-Specs";
const spec = (n: number, status = true): void => {
  const id = `SPEC-00${n}`;
  put(`${G}/${id}-s${n}/${id}-s${n}.md`, ["---", `id: ${id}`, ...(status ? ["status: Draft"] : []), "---", `# ${id}`, "## Delivery Brief", "x", "## Acceptance Criteria", "- AC-1 x", "## Backlog", "x", "## Architecture", "x", ""].join(NL));
};
const roadmap = (n: number, extra = ""): void =>
  put(`${G}/ROADMAP.md`, ["# Roadmap", extra, "## Execution Plan", "| Order | Spec | Depends on |", "|--|--|--|", ...Array.from({ length: n }, (_, i) => `| ${i + 1} | SPEC-00${i + 1} | None |`), ""].join(NL));
const check = () => runTool(root, "check-run-conformance", ["--scope", "specs", "--run-profile", "fasttrack"], { capture: true });

describe("fast-track spec budget and spec status", () => {
  test("setup", () => {
    applyPayload(root);
    for (let i = 1; i <= 9; i++) spec(i);
    roadmap(9);
  });
  test("more specs than the budget (default 8) is rejected under fast track", () => {
    expect(check().stdout).toContain("fast-track budget is 8");
  });
  test("a split the human approved in ROADMAP.md is accepted", () => {
    roadmap(9, "Spec budget: 9 (human approved)");
    expect(check().stdout).not.toContain("fast-track budget");
  });
  test("a spec without a status in its frontmatter is rejected", () => {
    spec(2, false);
    expect(check().stdout).toContain("SPEC-010");
  });
});
