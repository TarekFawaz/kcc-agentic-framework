import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { applyPayload } from "../src/lock";
import { runTool } from "../src/platform";

/**
 * PLAN-007: every architecture gate the plan cites maps to a Test ID, a quality-gate check, or a verifier step.
 * Round 10: QG-STATIC had no test in the plan (Bug-001) and the image scan behind QG-PROD item 7 was claimed
 * but never mapped to a check that scans the built images (Bug-004). Both tool variants run on every case.
 */
setDefaultTimeout(300000);
const temp = mkdtempSync(join(tmpdir(), "kcc-gates-"));
afterAll(() => rmSync(temp, { recursive: true, force: true }));
const NL = String.fromCharCode(10);

const GATES = [
  "# Quality Gates", "",
  "## Framework gates", "",
  "| ID | Gate | Evidence required | Applies to | Source | Status |", "|--|--|--|--|--|--|",
  "| QG-TRACE | Every AC is proven by a test | check-traceability exits 0 | every spec | framework | active |",
  "| QG-PROD | Production readiness | See the checklist below | E1 | D5 | active |", "",
  "### QG-PROD checklist (evidence per item)", "",
  "| # | Item | Evidence |", "|--|--|--|",
  "| 1 | Health and readiness | GET /healthz returns 200 |",
  "| 2 | Config from environment | no hard-coded secrets |",
  "| 7 | SBOM and scan | SBOM for both images (QG-SBOM); image scan has no critical findings (QG-IMAGE) |", "",
  "## Project gates", "",
  "| ID | Gate | Evidence required | Applies to | Source | Status |", "|--|--|--|--|--|--|",
  "| QG-STATIC | No raw SQL outside repository files | Lint rule or grep gate | every spec | Guardrails | active |",
  "| QG-A11Y | Main screens pass axe | vitest-axe | E5 | D19 | active |", "",
].join(NL);

const PLAN_HEAD = [
  "# SPEC-001 Implementation Plan", "",
  "## Architecture Gate Check",
  "- Gates: QG-TRACE, QG-PROD (owned here), QG-STATIC, QG-A11Y (shell).", "",
  "## Waves", "| Wave | Items | Files | File-disjoint | Notes |", "|--|--|--|--|--|", "| 1 | Story-001 | a | yes | |", "",
  "## Atomic test cases",
  "| Test ID | Item | AC | Level | Description |", "|--|--|--|--|--|",
  "| T-001 | Story-001 | AC-1 | unit | health returns 200 |",
  "| T-002 | Story-001 | AC-2 | unit | config guard |",
  "| T-003 | Story-001 | AC-3 | unit | static gate: no raw SQL outside repository files |",
  "| T-004 | Story-001 | AC-4 | unit | axe on the shell |",
  "| T-005 | Story-001 | AC-5 | unit | axe keyboard |", "",
].join(NL);

const TABLE = (rows: string[]) => ["## Gates coverage", "| Gate | Covered by |", "|--|--|", ...rows, ""].join(NL);
const FULL_ROWS = [
  "| QG-TRACE | check:QG-TEST |",
  "| QG-PROD-1 | T-001 |",
  "| QG-PROD-2 | T-002 |",
  "| QG-PROD-7 | check:QG-SBOM, check:QG-IMAGE |",
  "| QG-STATIC | T-003 |",
  "| QG-A11Y | T-004..T-005, verifier:visual review of the dark theme |",
];

let n = 0;
function workspace(plan: string, withGates = true, extra: Record<string, string> = {}): string {
  const root = join(temp, `w${++n}`);
  applyPayload(root);
  const put = (rel: string, text: string) => {
    mkdirSync(dirname(join(root, rel)), { recursive: true });
    writeFileSync(join(root, rel), text);
  };
  const spec = "specs/IDEA-001-demo-Specs/SPEC-001-core";
  put(`${spec}/SPEC-001-core.md`, "# SPEC-001" + NL);
  put(`${spec}/Backlog/Story-001-feature.md`, "# Story-001" + NL);
  put(`${spec}/plan.md`, plan);
  if (withGates) put("architecture/quality-gates.md", GATES);
  for (const [rel, text] of Object.entries(extra)) put(rel, text);
  return root;
}

type Run = { status: number; out: string };
const args = (root: string) => ["--repo-root", root, "--scope", "plan", "--spec", "SPEC-001"];
const viaPs: (root: string) => Run = (root) => {
  const r = runTool(root, "check-run-conformance", args(root), { capture: true });
  return { status: r.status, out: r.stdout };
};
const viaSh: (root: string) => Run = (root) => {
  const r = spawnSync("bash", [join(root, ".KCC", "tools", "check-run-conformance.sh"), ...args(root)], { cwd: root, encoding: "utf8" });
  return { status: r.status ?? 1, out: (r.stdout ?? "") + (r.stderr ?? "") };
};
const GUARDRAILS = [
  "## Guardrails", "",
  "| ID | Guardrail | Enforced by | Source |", "|--|--|--|--|",
  "| GR-001 | No raw SQL outside infrastructure | SR-001 | D5 |",
  "| GR-002 | Money is integer minor units | SR-003 | D7 |",
  "| GR-012 | Declared libraries (Decisions table) are the ones used | QG-ARCH-CONFORMANCE | governance |", "",
].join(NL);
const TSV = (...c: string[]) => c.join(String.fromCharCode(9));
const STATIC_RULES = ["# rules", TSV("id", "files", "forbidden", "allowed_in", "message"), TSV("SR-001", "[.]ts$", "prepare", "", "(GR-001)"), TSV("SR-003", "[.]ts$", "parseFloat", "", "(GR-002)"), ""].join(NL);
const GR_ROWS = ["| GR-001 | static-rules:SR-001 |", "| GR-002 | static-rules:SR-003, T-003 |", "| GR-012 | verifier:every package in the Decisions table is imported by src and in the lockfile |"];
const withGr = (extra: Record<string, string> = {}) => ({ "architecture/quality-gates.md": GATES + NL + GUARDRAILS, "architecture/static-rules.tsv": STATIC_RULES, ...extra });
const plan007 = (out: string) => out.split(/\r?\n/).filter((l) => l.includes("PLAN-007"));

for (const [label, run] of [["check-run-conformance.ps1", viaPs], ["check-run-conformance.sh", viaSh]] as const) {
  describe(`PLAN-007 gates coverage (${label})`, () => {
    test("a plan with no Gates coverage table fails PLAN-007", () => {
      const r = run(workspace(PLAN_HEAD));
      expect(r.status).toBe(1);
      const v = plan007(r.out);
      expect(v.length).toBe(1);
      expect(v[0]).toContain("[ERROR]");
      expect(v[0]).toContain("## Gates coverage");
    });

    test("a complete table passes: Test IDs and ranges, check:<QG-ID>, verifier:<step>, one row per QG-PROD item", () => {
      const r = run(workspace(PLAN_HEAD + TABLE(FULL_ROWS)));
      expect(plan007(r.out)).toEqual([]);
    });

    test("a Test ID that is not in the atomic table fails and is named", () => {
      const rows = FULL_ROWS.map((x) => x.replace("| QG-STATIC | T-003 |", "| QG-STATIC | T-099 |"));
      const r = run(workspace(PLAN_HEAD + TABLE(rows)));
      expect(r.status).toBe(1);
      const v = plan007(r.out).join(NL);
      expect(v).toContain("QG-STATIC");
      expect(v).toContain("T-099");
    });

    test("a gate the Gates line cites without a row fails and is named; QG-PROD items are required one by one", () => {
      const rows = FULL_ROWS.filter((x) => !x.startsWith("| QG-STATIC") && !x.startsWith("| QG-PROD-7"));
      const r = run(workspace(PLAN_HEAD + TABLE(rows)));
      expect(r.status).toBe(1);
      const v = plan007(r.out).join(NL);
      expect(v).toContain("has no row for: QG-STATIC");
      expect(v).toContain("QG-PROD-7");
      expect(v).not.toContain("QG-PROD-1,");
      expect(v).not.toContain("QG-A11Y,");
    });

    test("an empty Covered by, an unknown check: and a bare verifier: each fail", () => {
      const rows = FULL_ROWS.map((x) => x.replace("| QG-STATIC | T-003 |", "| QG-STATIC |  |").replace("| QG-PROD-2 | T-002 |", "| QG-PROD-2 | check:QG-NOPE |").replace("| QG-TRACE | check:QG-TEST |", "| QG-TRACE | verifier: |"));
      const r = run(workspace(PLAN_HEAD + TABLE(rows)));
      expect(r.status).toBe(1);
      const v = plan007(r.out).join(NL);
      expect(v).toContain("QG-STATIC: empty Covered by");
      expect(v).toContain('unknown check "QG-NOPE"');
      expect(v).toContain("QG-TRACE: verifier: names no step");
    });

    test("without architecture/quality-gates.md the rule does not apply", () => {
      const r = run(workspace(PLAN_HEAD, false));
      expect(plan007(r.out)).toEqual([]);
    });

    test("guardrails: a row per GR-nnn with Test ID, check:, verifier:, static-rules:<rule-id> or n/a:<reason> passes", () => {
      const rows = [...FULL_ROWS, ...GR_ROWS];
      expect(plan007(run(workspace(PLAN_HEAD + TABLE(rows), true, withGr())).out)).toEqual([]);
      const grouped = [...FULL_ROWS, "| GR-001, GR-002 | check:QG-STATIC |", "| GR-012 | n/a: this spec adds no dependency |"];
      expect(plan007(run(workspace(PLAN_HEAD + TABLE(grouped), true, withGr())).out)).toEqual([]);
    });

    test("guardrails: a guardrail without a row fails and is named (GR-012 in round 11)", () => {
      const rows = [...FULL_ROWS, GR_ROWS[0]!, GR_ROWS[1]!];
      const r = run(workspace(PLAN_HEAD + TABLE(rows), true, withGr()));
      expect(r.status).toBe(1);
      const v = plan007(r.out).join(NL);
      expect(v).toContain("no row for guardrail(s): GR-012");
      expect(v).not.toContain("GR-001,");
    });

    test("guardrails: an unknown static rule, static-rules: without the file, a bare static-rules:, and n/a: without a reason fail", () => {
      const rows = [...FULL_ROWS, "| GR-001 | static-rules:SR-099 |", "| GR-002 | static-rules: |", "| GR-012 | n/a: |"];
      const v1 = plan007(run(workspace(PLAN_HEAD + TABLE(rows), true, withGr())).out).join(NL);
      expect(v1).toContain('GR-001: unknown static rule "SR-099"');
      expect(v1).toContain("GR-002: static-rules: names no rule id");
      expect(v1).toContain("GR-012: n/a: names no reason");
      const noFile = withGr();
      delete (noFile as Record<string, string>)["architecture/static-rules.tsv"];
      const v2 = plan007(run(workspace(PLAN_HEAD + TABLE([...FULL_ROWS, ...GR_ROWS]), true, noFile)).out).join(NL);
      expect(v2).toContain("static-rules: but architecture/static-rules.tsv does not exist");
    });

    test("guardrails: n/a: is refused on a quality gate row, and a retired guardrail is not required", () => {
      const rows = FULL_ROWS.map((x) => x.replace("| QG-A11Y | T-004..T-005, verifier:visual review of the dark theme |", "| QG-A11Y | n/a: no ui |")).concat(GR_ROWS);
      expect(plan007(run(workspace(PLAN_HEAD + TABLE(rows), true, withGr())).out).join(NL)).toContain("QG-A11Y: n/a: is allowed only for a guardrail");
      const guardrails = ["# Guardrails", "", "| ID | Guardrail | Applies to | Source ADR | Status |", "|--|--|--|--|--|",
        "| GR-001 | No raw SQL | all | ADR-1 | active |", "| GR-002 | Old rule | all | ADR-2 | retired |", ""].join(NL);
      const r = run(workspace(PLAN_HEAD + TABLE([...FULL_ROWS, "| GR-001 | T-003 |"]), true, { "architecture/guardrails.md": guardrails }));
      expect(plan007(r.out)).toEqual([]);
    });

    test("guardrails without quality-gates.md still need a Gates coverage table", () => {
      const r = run(workspace(PLAN_HEAD, false, { "architecture/guardrails.md": "| ID | Guardrail |" + NL + "|--|--|" + NL + "| GR-001 | No raw SQL |" + NL }));
      expect(r.status).toBe(1);
      expect(plan007(r.out).length).toBe(1);
    });
  });
}
