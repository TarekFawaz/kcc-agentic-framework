import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { applyPayload } from "../src/lock";
import { runTool } from "../src/platform";

// Test round 5 produced 15 specs for a small app and no runnable output after hours. Fast track now has a spec
// budget the human approves, and every spec must carry a status. Round 13 chained seven file-disjoint specs one
// after the other (SPEC-002 after 001, 003 after 002, ...): SPEC-011 warns when the split is a single chain.
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
  put(`${G}/${id}-s${n}/${id}-s${n}.md`, ["---", `id: ${id}`, ...(status ? ["status: Draft"] : []), "---", `# ${id}`, "## Delivery Brief", "x", "## Acceptance Criteria", "- AC-1 x", "## Backlog", "x", "## Architecture references", "- [[../../../architecture/architecture]]", ""].join(NL));
};
const roadmap = (n: number, extra = "", dep: (i: number) => string = () => "None"): void =>
  put(`${G}/ROADMAP.md`, ["# Roadmap", extra, "## Execution Plan", "| Order | Spec | Depends on |", "|--|--|--|", ...Array.from({ length: n }, (_, i) => `| ${i + 1} | SPEC-00${i + 1} | ${dep(i + 1)} |`), ""].join(NL));
const check = () => runTool(root, "check-run-conformance", ["--scope", "specs", "--run-profile", "fasttrack"], { capture: true });
const chain = (i: number): string => (i === 1 ? "None" : `SPEC-00${i - 1}`);
const skeletonOnly = (i: number): string => (i === 1 ? "None" : "SPEC-001");

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
  test("no arch.md is expected under fast track, and one that exists is a warning, not an error", () => {
    spec(2);
    expect(check().stdout).not.toContain("SPEC-003");
    put(`${G}/SPEC-003-s3/arch.md`, "# slice");
    const out = check().stdout;
    expect(out).toContain("[WARNING] SPEC-003");
    expect(out).toContain("fast track writes none");
    rmSync(join(root, G, "SPEC-003-s3", "arch.md"));
  });
});

describe("SPEC-011: a serial split is a warning under fast track", () => {
  const fresh = (n: number, dep: (i: number) => string, extra = ""): void => {
    rmSync(join(root, "specs"), { recursive: true, force: true });
    for (let i = 1; i <= n; i++) spec(i);
    roadmap(n, extra, dep);
  };
  test("every spec depending on exactly the previous one is reported, as a warning owned by the spec-writer", () => {
    fresh(4, chain);
    const out = check().stdout;
    expect(out).toContain("[WARNING] SPEC-011 (spec-writer)");
    expect(out).toContain("the split is serial: every feature spec depends on the previous one; name only build-time dependencies so independent specs build in parallel");
  });
  test("feature specs that depend on the walking skeleton only are not reported", () => {
    fresh(4, skeletonOnly);
    expect(check().stdout).not.toContain("SPEC-011");
  });
  test("one real build-time dependency inside an otherwise parallel split is not reported", () => {
    fresh(4, (i) => (i === 1 ? "None" : i === 3 ? "SPEC-002" : "SPEC-001"));
    expect(check().stdout).not.toContain("SPEC-011");
  });
  test("two specs are never a chain, and a wikilinked Spec column is parsed", () => {
    fresh(2, chain);
    expect(check().stdout).not.toContain("SPEC-011");
    put(`${G}/ROADMAP.md`, ["# Roadmap", "## Execution Plan", "| Order | Spec | Delivery | Depends on | Lane |", "|--|--|--|--|--|",
      "| 1 | [[SPEC-001-s1/SPEC-001-s1\\|SPEC-001]] | a | None | A |", "| 2 | [[SPEC-002-s2/SPEC-002-s2\\|SPEC-002]] | b | SPEC-001 | A |", "| 3 | [[SPEC-003-s3/SPEC-003-s3\\|SPEC-003]] | c | [[SPEC-002-s2/SPEC-002-s2\\|SPEC-002]] | A |", ""].join(NL));
    spec(3);
    expect(check().stdout).toContain("SPEC-011");
  });
  test("the full lifecycle is unchanged: no SPEC-011, and arch.md is still required", () => {
    fresh(4, chain);
    const out = runTool(root, "check-run-conformance", ["--scope", "specs"], { capture: true }).stdout;
    expect(out).not.toContain("SPEC-011");
    expect(out).toContain("SPEC-003");
  });
});
