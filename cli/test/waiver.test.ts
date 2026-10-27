import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { cpSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { isWindows, runTool } from "../src/platform";

/**
 * Round 12 (BudgetPal, SPEC-001): every Bug was fixed and verified, yet the review stayed CHANGES_NEEDED because the quality gate was
 * red for things no code change can turn green (a gate tool that exited 127, an image left over from an earlier round, a scanner
 * that was not installed). The driver sent the spec back to FIX three times (a 108-second run that wrote nothing, twice) and parked
 * it. These tests drive both kcc-run drivers against the stub harness and prove the routed outcome:
 *  - a WAIVER_NEEDED review with every bug closed opens the waiver gate, which a silent run answers `waive`: no FIX, the spec closes
 *    as WAIVER_NEEDED (never a pass), the run goes on, NeedsAttention.md and the last message say what a human does;
 *  - a CHANGES_NEEDED review with no open bug, no failing gate check an implementer owns and no traceability error is read the same
 *    way (REVIEW-004, "read as WAIVER_NEEDED"), so the implementer is never run for nothing;
 *  - a CHANGES_NEEDED review with an open bug still goes to FIX;
 *  - a scoped TEST on the reviewed commit with nothing changed and no Bug awaiting verification runs no verifier (test-skipped).
 */
setDefaultTimeout(process.env.KCC_TEST_ALL_DRIVERS === "1" ? 3600000 : 1200000);
const temp = mkdtempSync(join(tmpdir(), "kcc-waiver-"));
afterAll(() => rmSync(temp, { recursive: true, force: true }));
const STUB = join(import.meta.dir, "fixtures", "stub-harness.sh");

const stubPs = (name: string): string => `$root = $null
for ($i = 0; $i -lt @($args).Count; $i++) { if ($args[$i] -eq '-RepoRoot') { $root = $args[$i + 1] } }
$d = Join-Path $root '.kcc-stub'
$rc = 0; $f = Join-Path $d '${name}.rc'; if (Test-Path -LiteralPath $f) { $rc = [int]((Get-Content -LiteralPath $f -Raw).Trim()) }
$j = Join-Path $d '${name}.json'
if (Test-Path -LiteralPath $j) { Get-Content -LiteralPath $j -Raw } else { '{"status":"pass","violations":[]}' }
exit $rc
`;
const stubSh = (name: string): string => `#!/usr/bin/env bash
root=""; while [ $# -gt 0 ]; do [ "$1" = "--repo-root" ] && root="$2"; shift; done
d="$root/.kcc-stub"; rc=0
[ -f "$d/${name}.rc" ] && rc="$(tr -d '\\r\\n ' < "$d/${name}.rc")"
if [ -f "$d/${name}.json" ]; then cat "$d/${name}.json"; else echo '{"status":"pass","violations":[]}'; fi
exit "$rc"
`;
const STUBBED = ["quality-gate", "check-traceability", "check-run-conformance"];
// A gate that passed every check it ran: nothing for an implementer, nothing deferred.
const GREEN_QG = JSON.stringify({ tool: "quality-gate", status: "pass", exit_code: 0, errors: 0, warnings: 0, deferred: 0, missing_tools: [], checks: [{ id: "QG-TEST", status: "pass", fix_owner: "implementer", message: "all tests pass" }, { id: "QG-DEPS", status: "pass", fix_owner: "implementer", message: "none at or above high" }], violations: [] });

function baseWorkspace(): string {
  const root = join(temp, "base");
  applyPayload(root);
  const git = (...a: string[]) => spawnSync("git", a, { cwd: root, encoding: "utf8" });
  git("init", "-q"); git("config", "user.email", "t@example.com"); git("config", "user.name", "T"); git("config", "core.autocrlf", "false");
  writeFileSync(join(root, "README.md"), "demo\n");
  git("add", "-A"); git("commit", "-q", "-m", "base");
  mkdirSync(join(root, ".kcc-stub"), { recursive: true });
  copyFileSync(STUB, join(root, ".kcc-stub", "stub.sh"));
  writeFileSync(join(root, ".kcc-stub", "mode"), "happy");
  const sp = join(root, ".KCC", "settings.json");
  const s = JSON.parse(readFileSync(sp, "utf8"));
  s.run.harness = "generic";
  s.continuity.start.generic = 'bash .kcc-stub/stub.sh "{resume_prompt}"';
  s.continuity.resume.generic = 'bash .kcc-stub/stub.sh "{resume_prompt}"';
  writeFileSync(sp, JSON.stringify(s, null, 2));
  return root;
}
const ps = (root: string, args: string[]) => runTool(root, "kcc-run", args, { capture: true });
const sh = (root: string, args: string[]) => {
  const r = spawnSync("bash", [join(root, ".KCC", "tools", "kcc-run.sh"), ...args, "--repo-root", root], { cwd: root, encoding: "utf8" });
  return { status: r.status ?? 1, stdout: (r.stdout ?? "") + (r.stderr ?? "") };
};
const FT = ["--input", "a tiny app", "--silent", "--assume", "--fasttrack"];
// KCC_TEST_DRIVERS=bash|powershell|both picks the drivers; the default is the OS driver (PowerShell on Windows, bash elsewhere),
// plus bash on Windows when KCC_TEST_ALL_DRIVERS=1 (slow under Git Bash: every process costs ~0.4 s).
const want = (process.env.KCC_TEST_DRIVERS ?? (isWindows ? (process.env.KCC_TEST_ALL_DRIVERS === "1" ? "both" : "powershell") : "bash")).toLowerCase();
const drivers: [string, typeof sh][] = [];
if (isWindows && (want === "powershell" || want === "both")) drivers.push(["powershell", ps]);
if (want === "bash" || want === "both" || !isWindows) drivers.push(["bash", sh]);
const osDriver = drivers[0]![1];
let base = "";
beforeAll(() => {
  base = baseWorkspace();
  expect(osDriver(base, [...FT, "--until", "15"]).status).toBe(0);
});
let n = 0;
function scenario(): string {
  const root = join(temp, `s${++n}`);
  cpSync(base, root, { recursive: true });
  for (const t of STUBBED) {
    writeFileSync(join(root, ".KCC", "tools", `${t}.ps1`), stubPs(t));
    writeFileSync(join(root, ".KCC", "tools", `${t}.sh`), stubSh(t));
  }
  return root;
}
const stubFile = (root: string, rel: string, text: string): void => writeFileSync(join(root, ".kcc-stub", rel), text);
const specDir = (root: string): string => {
  const dir = readdirSync(join(root, "specs")).find((d) => d.startsWith("IDEA-"))!;
  const spec = readdirSync(join(root, "specs", dir)).find((d) => d.startsWith("SPEC-"))!;
  return join(root, "specs", dir, spec);
};
const bugText = (name: string, status: string) => `# ${name}: a finding

| Type | Parent | Source | Severity | Status | Story / AC | Regression test | Evidence |
|--|--|--|--|--|--|--|--|
| Bug | [[../SPEC-001]] | verifier | major | ${status} | Story-001 / AC-1 | T-001 | none |

## Impacted Files
- src/IDEA-001-demo/app.ts
`;
const putBug = (root: string, name: string, status: string): void => {
  mkdirSync(join(specDir(root), "Backlog"), { recursive: true });
  writeFileSync(join(specDir(root), "Backlog", `${name}-finding.md`), bugText(name, status));
};
const text = (root: string, rel: string): string => (existsSync(join(root, rel)) ? readFileSync(join(root, rel), "utf8") : "");
const calls = (root: string, state: number): number => text(root, ".kcc-stub/calls.log").split(/\r?\n/).filter((l) => new RegExp(`state=${state}\\b`).test(l)).length;
const events = (root: string): any[] => text(root, "coordination/backchannel.jsonl").split(/\r?\n/).filter(Boolean).map((l) => JSON.parse(l));
const runJson = (root: string): any => JSON.parse(text(root, "coordination/run/run.json"));
const head = (root: string): string => spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).stdout.trim();
const commitAll = (root: string): void => {
  spawnSync("git", ["add", "-A"], { cwd: root, encoding: "utf8" });
  spawnSync("git", ["commit", "-q", "-m", "SPEC-001 Story-001: waves"], { cwd: root, encoding: "utf8" });
};
const reviewMd = (verdict: string, commit: string): string => `---\nspec-id: SPEC-001\nstatus: ${verdict.toLowerCase().replace("_", "-")}\nverdict: ${verdict}\ncommit: ${commit}\n---\n# SPEC-001\n\n## Evidence\n- \`quality-gate\` exit 0\n\n## Verdict\n**${verdict}**\n`;

for (const [dname, run] of drivers) {
  describe(`a gate no code change can turn green is a waiver, not a loop (${dname})`, () => {
    test("a deferral accepted at TEST (exit 3) does not hide the waiver at REVIEW: the waiver gate still opens (round 14, SPEC-001)", () => {
      const root = scenario();
      putBug(root, "Bug-001", "verified");
      stubFile(root, "verdict", "WAIVER_NEEDED");
      stubFile(root, "check-traceability.rc", "3");
      stubFile(root, "quality-gate.rc", "0");
      stubFile(root, "quality-gate.json", GREEN_QG);
      const r = run(root, ["--resume", "--from", "16", "--until", "17"]);
      expect(r.status).toBe(0);
      expect(calls(root, 19)).toBe(0);
      const d = events(root).filter((e) => e.kind === "deferral-accepted");
      expect(d.map((e) => e.payload.gate)).toEqual(["quality-deferred-on-exit-3", "waiver"]);
      expect(d[1].payload.verdict).toBe("WAIVER_NEEDED");
      expect(events(root).some((e) => e.kind === "human-gate-triggered" && e.payload.gate === "waiver")).toBe(true);
      expect(r.stdout).toContain("WAIVER NEEDED, NOT A PASS");
      expect(text(root, "coordination/NeedsAttention.md")).toContain("## [decided] SPEC-001 | waiver");
    });

    test("WAIVER_NEEDED with every bug closed: TEST once, REVIEW once, no FIX; the spec closes as WAIVER_NEEDED by policy and the message says what a human does", () => {
      const root = scenario();
      putBug(root, "Bug-001", "verified");
      stubFile(root, "verdict", "WAIVER_NEEDED");
      stubFile(root, "quality-gate.rc", "0");
      stubFile(root, "quality-gate.json", GREEN_QG);
      const r = run(root, ["--resume", "--from", "16", "--until", "17"]);
      expect(r.status).toBe(0); // a waiver is a decided item: the run goes on, nothing is open
      expect(calls(root, 16)).toBe(1);
      expect(calls(root, 17)).toBe(1);
      expect(calls(root, 19)).toBe(0);
      expect(r.stdout).toContain("WAIVER NEEDED, NOT A PASS");
      expect(r.stdout).toContain("SPEC-001");
      expect(r.stdout).not.toContain("PAUSED");
      const d = events(root).filter((e) => e.kind === "deferral-accepted");
      expect(d.length).toBe(1);
      expect(d[0].payload).toMatchObject({ verdict: "WAIVER_NEEDED", by: "policy", gate: "waiver" });
      const g = events(root).filter((e) => e.kind === "human-gate-triggered" && e.payload.gate === "waiver");
      expect(g.length).toBe(1);
      expect(g[0].payload.allowed_answers).toEqual(["waive", "recheck", "abort"]);
      expect(events(root).some((e) => e.kind === "human-gate-decision" && e.payload.gate === "waiver" && e.payload.answered_by === "policy" && e.payload.answer === "waive")).toBe(true);
      expect(runJson(root).attempts).toContain("defer:SPEC-001=1");
      expect(runJson(root).gate_id).toBe("");
      const na = text(root, "coordination/NeedsAttention.md");
      expect(na).toContain("## [decided] SPEC-001 | waiver");
      expect(na).toContain("WAIVER_NEEDED");
      expect(na).toMatch(/- todo: .*(kcc-run|kcc run)/);
      expect(na).toContain("REVIEW-004");
    });

    test("CHANGES_NEEDED with no open bug, a green gate and no traceability error is read as WAIVER_NEEDED: no FIX run", () => {
      const root = scenario();
      putBug(root, "Bug-001", "verified");
      stubFile(root, "verdict", "CHANGES_NEEDED");
      stubFile(root, "quality-gate.rc", "0");
      stubFile(root, "quality-gate.json", GREEN_QG);
      const r = run(root, ["--resume", "--from", "16", "--until", "17"]);
      expect(r.status).toBe(0);
      expect(calls(root, 19)).toBe(0);
      expect(calls(root, 17)).toBe(1);
      expect(r.stdout).toContain("WAIVER NEEDED, NOT A PASS");
      const na = text(root, "coordination/NeedsAttention.md");
      expect(na).toContain("## [decided] SPEC-001 | waiver");
      expect(na).toContain("read as WAIVER_NEEDED");
      expect(events(root).filter((e) => e.kind === "deferral-accepted").pop().payload.verdict).toBe("WAIVER_NEEDED");
    });

    test("CHANGES_NEEDED with an open bug is still work for the implementer: FIX runs, no waiver gate", () => {
      const root = scenario();
      putBug(root, "Bug-002", "open");
      stubFile(root, "verdict", "CHANGES_NEEDED");
      stubFile(root, "quality-gate.rc", "0");
      stubFile(root, "quality-gate.json", GREEN_QG);
      // TEST writes the review, REVIEW sends the open bug back (REVIEW-002), FIX closes it; the run stops after FIX (--until 19)
      const r = run(root, ["--resume", "--from", "16", "--until", "19"]);
      expect(r.status).toBe(0);
      expect(calls(root, 17)).toBe(1);
      expect(calls(root, 19)).toBe(1);
      expect(events(root).some((e) => e.kind === "human-gate-triggered" && e.payload.gate === "waiver")).toBe(false);
      expect(events(root).some((e) => e.kind === "deferral-accepted")).toBe(false);
    });

    test("a scoped TEST on the reviewed commit with nothing changed and no Bug awaiting verification runs no verifier", () => {
      const root = scenario();
      commitAll(root); // the implementer commits its waves; the review records that HEAD
      writeFileSync(join(specDir(root), "review.md"), reviewMd("CHANGES_NEEDED", head(root)));
      stubFile(root, "quality-gate.rc", "0");
      stubFile(root, "quality-gate.json", GREEN_QG);
      const r = run(root, ["--resume", "--from", "16", "--until", "16"]);
      expect(r.status).toBe(0);
      expect(calls(root, 16)).toBe(0);
      expect(r.stdout).toContain("nothing changed since the last review");
      const sk = events(root).filter((e) => e.kind === "test-skipped");
      expect(sk.length).toBe(1);
      expect(sk[0].payload).toMatchObject({ reason: "unchanged since the last review" });
      expect(head(root).startsWith(sk[0].payload.commit)).toBe(true);
      expect(events(root).some((e) => e.kind === "test-completed")).toBe(true);
    });

    test("a scoped TEST with a Bug fixed but not yet verified is dispatched", () => {
      const root = scenario();
      commitAll(root);
      writeFileSync(join(specDir(root), "review.md"), reviewMd("CHANGES_NEEDED", head(root)));
      putBug(root, "Bug-003", "fixed");
      stubFile(root, "verdict", "APPROVED");
      stubFile(root, "quality-gate.rc", "0");
      const r = run(root, ["--resume", "--from", "16", "--until", "16"]);
      expect(r.status).toBe(0);
      expect(calls(root, 16)).toBe(1);
      expect(events(root).some((e) => e.kind === "test-skipped")).toBe(false);
    });
  });
}
