import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { cpSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { isWindows, runTool } from "../src/platform";

/**
 * Round 11 (BudgetPal, SPEC-001), notes 28 and 31: after the fixes, the scoped TEST found every bug verified and only QG-SAST
 * deferred (semgrep missing). The verdict QUALITY_DEFERRED then looped into a FIX run that found nothing to do (86 s) and a second
 * FULL xhigh TEST that repeated the same checks. These tests drive both kcc-run drivers against the stub harness
 * (test/fixtures/stub-harness.sh) with stubbed quality-gate / check-traceability / check-run-conformance tools (the state machine is
 * under test, not the scanners) and prove:
 *  - all bugs closed + a deferred scanner: no FIX, no second TEST, the spec ends as deferred-accepted and the last message names
 *    the missing tool and how to install it and re-run the gate;
 *  - a deferred-only outcome never uses the second full pass (QUALITY_DEFERRED is re-verified scoped);
 *  - a FIX with nothing for the implementer is skipped (fix-completed, skipped: true, no agent run);
 *  - every dispatch has its own log (state-16-SPEC-001-2.log), and agent-run-started carries tier, reasons, pass;
 *  - under --silent --assume nothing pauses: a blocked bug is ruled by policy, three failed exit checks park the spec as
 *    needs-attention (exit 7), everything is written to coordination/NeedsAttention.md.
 */
// One bash scenario takes 10-15 minutes under Git Bash on Windows (forks), so the bash-everywhere run gets a longer per-test limit.
setDefaultTimeout(process.env.KCC_TEST_ALL_DRIVERS === "1" ? 3600000 : 900000);
const temp = mkdtempSync(join(tmpdir(), "kcc-verdict-"));
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
const DEFERRED_QG = JSON.stringify({ tool: "quality-gate", status: "deferred", exit_code: 3, deferred: 1, missing_tools: ["semgrep"], checks: [{ id: "QG-TEST", status: "pass" }, { id: "QG-SAST", status: "deferred" }], violations: [{ id: "QG-SAST", severity: "warning", fix_owner: "human", message: "tool semgrep is missing; deferred (not a pass)" }] });
const REVIEW_FAIL = JSON.stringify({ status: "fail", violations: [{ id: "REV-003", severity: "error", fix_owner: "verifier", message: "review.md has no Evidence block" }] });

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
const osDriver = isWindows ? ps : sh;
const FT = ["--input", "a tiny app", "--silent", "--assume", "--fasttrack"];
// The shared preparation (IDEA .. IMPLEMENT) runs once, in the OS driver; every scenario works on a copy of it.
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
const bugText = (name: string, status: string, ruling = false) => `# ${name}: a finding

| Type | Parent | Source | Severity | Status | Story / AC | Regression test | Evidence |
|--|--|--|--|--|--|--|--|
| Bug | [[../SPEC-001]] | verifier | major | ${status} | Story-001 / AC-1 | T-001 | none |

## Impacted Files
- src/IDEA-001-demo/app.ts
${ruling ? `
## Ruling needed
- Blocker: the library the code uses differs from the one the architecture names.
- Options: (A) amend the Decisions table (B) rebuild on the declared library (C) waive.
- Recommended: A - smallest change.
` : ""}`;
const putBug = (root: string, name: string, status: string, ruling = false): string => {
  const f = join(specDir(root), "Backlog", `${name}-finding.md`);
  mkdirSync(join(specDir(root), "Backlog"), { recursive: true });
  writeFileSync(f, bugText(name, status, ruling));
  return f;
};
const text = (root: string, rel: string): string => (existsSync(join(root, rel)) ? readFileSync(join(root, rel), "utf8") : "");
const calls = (root: string, state: number): number => text(root, ".kcc-stub/calls.log").split(/\r?\n/).filter((l) => new RegExp(`state=${state}\\b`).test(l)).length;
const prompts = (root: string, state: number): string[] => text(root, ".kcc-stub/prompts.log").split(/\r?\n/).filter((l) => l.startsWith(`KCC run state ${state} `));
const events = (root: string): any[] => text(root, "coordination/backchannel.jsonl").split(/\r?\n/).filter(Boolean).map((l) => JSON.parse(l));
const runJson = (root: string): any => JSON.parse(text(root, "coordination/run/run.json"));
const logs = (root: string): string[] => readdirSync(join(root, "coordination", "run", "logs")).sort();

// PowerShell runs every scenario; the bash driver (very slow under Git Bash on Windows) runs the cheap ones there and all on Linux/macOS.
// KCC_TEST_ALL_DRIVERS=1 runs every scenario in bash on Windows too (hours; run it with a long --timeout).
const allBash = process.env.KCC_TEST_ALL_DRIVERS === "1";
const drivers: [string, typeof sh, boolean][] = isWindows ? [["powershell", ps, true], ["bash", sh, allBash]] : [["bash", sh, true]];

for (const [dname, run, every] of drivers) {
  const heavy = every ? test : test.skip;
  describe(`a deferred scanner is not a reason to loop (${dname})`, () => {
    test("every bug closed + QUALITY_DEFERRED: no FIX, no second TEST, the spec ends deferred-accepted and the message names the tool", () => {
      const root = scenario();
      putBug(root, "Bug-003", "verified");
      stubFile(root, "verdict", "QUALITY_DEFERRED");
      stubFile(root, "quality-gate.rc", "3");
      stubFile(root, "quality-gate.json", DEFERRED_QG);
      const r = run(root, ["--resume", "--from", "16", "--until", "17"]);
      expect(r.status).toBe(0); // deferred-accepted is a decided item, not an open one
      expect(calls(root, 16)).toBe(1);
      expect(calls(root, 17)).toBe(1);
      expect(calls(root, 19)).toBe(0);
      expect(r.stdout).toContain("DEFERRED, NOT A PASS");
      expect(r.stdout).toContain("SPEC-001");
      expect(r.stdout).toContain("semgrep");
      expect(r.stdout).toContain("QG-SAST");
      expect(r.stdout).toMatch(/toolchain-preflight[^\n]*semgrep/);
      expect(r.stdout).toMatch(/quality-gate[^\n]*SPEC-001/);
      expect(r.stdout).toMatch(/-until 17 reached/i);
      const d = events(root).filter((e) => e.kind === "deferral-accepted");
      expect(d.length).toBe(1);
      expect(d[0].payload).toMatchObject({ tools: "semgrep", verdict: "QUALITY_DEFERRED", by: "policy", gate: "quality-deferred-on-exit-3" });
      expect(runJson(root).attempts).toContain("defer:SPEC-001=1");
      expect(runJson(root).attempts).toContain("full:SPEC-001=1");
      expect(runJson(root).status).toBe("stopped");
      const na = text(root, "coordination/NeedsAttention.md");
      expect(na).toContain("## [decided] SPEC-001 | quality-deferred-on-exit-3");
      expect(na).toContain("semgrep");
      expect(events(root).some((e) => e.kind === "human-gate-decision" && e.payload.answered_by === "policy" && e.payload.answer === "accept-deferred")).toBe(true);
    });

    heavy("a QUALITY_DEFERRED review is re-verified scoped: the second full pass is not used", () => {
      const root = scenario();
      writeFileSync(join(specDir(root), "review.md"), "---\nspec-id: SPEC-001\nstatus: quality-deferred\nverdict: QUALITY_DEFERRED\ncommit: abc1234def5678\n---\n# SPEC-001\n\n## Verdict\n**QUALITY_DEFERRED**\n");
      stubFile(root, "quality-gate.rc", "0");
      const r = run(root, ["--resume", "--from", "16", "--until", "16"]);
      expect(r.status).toBe(0);
      const p = prompts(root, 16).pop() ?? "";
      expect(p).toContain("RE-VERIFICATION MODE");
      expect(p).toContain("verdict QUALITY_DEFERRED exists");
      expect(p).not.toContain("FULL VERIFICATION PASS");
      expect(runJson(root).attempts ?? "").not.toContain("full:SPEC-001");
      const sel = events(root).filter((e) => e.kind === "model-selected" && e.payload.agent === "verifier");
      expect(sel.pop().payload.pass).toBe("scoped");
    });

    heavy("QUALITY_DEFERRED with a bug still open goes to FIX once; the next TEST is scoped; two logs, justification fields on the start events", () => {
      const root = scenario();
      putBug(root, "Bug-004", "open");
      stubFile(root, "verdict", "QUALITY_DEFERRED");
      stubFile(root, "quality-gate.rc", "3");
      stubFile(root, "quality-gate.json", DEFERRED_QG);
      const r = run(root, ["--resume", "--from", "16", "--until", "17"]);
      expect(r.status).toBe(0);
      expect(calls(root, 19)).toBe(1); // the open bug is real work
      expect(calls(root, 16)).toBe(2);
      expect(calls(root, 17)).toBe(2);
      expect(/\| fixed \|/.test(text(root, `${specDir(root).slice(root.length + 1).replace(/\\/g, "/")}/Backlog/Bug-004-finding.md`))).toBe(true);
      expect(runJson(root).attempts).toContain("full:SPEC-001=1"); // the second TEST did not take the second full pass
      expect(prompts(root, 16)[1]).toContain("RE-VERIFICATION MODE");
      // one log per dispatch; the second TEST does not overwrite the first
      const l = logs(root);
      expect(l).toContain("state-16-SPEC-001-1.log");
      expect(l).toContain("state-16-SPEC-001-2.log");
      expect(l.filter((f) => /^check-16_SPEC-001-\d-quality-gate\.out$/.test(f)).length).toBe(2);
      // every dispatch says why its model was chosen without joining events
      const started = events(root).filter((e) => e.kind === "agent-run-started" && e.payload.state === 16);
      expect(started.map((e) => e.payload.pass)).toEqual(["full", "scoped"]);
      expect(started.map((e) => e.payload.dispatch)).toEqual([1, 2]);
      for (const e of started) {
        expect(typeof e.payload.tier).toBe("string");
        expect(e.payload.tier.length).toBeGreaterThan(0);
        expect(typeof e.payload.reasons).toBe("string");
        expect(e.payload.reasons.length).toBeGreaterThan(0);
      }
      const ended = events(root).filter((e) => e.kind === "agent-run-ended" && e.payload.state === 16);
      expect(ended.map((e) => e.payload.log)).toEqual(started.map((e) => e.payload.log));
    });
  });

  describe(`a FIX with nothing for the implementer is skipped (${dname})`, () => {
    heavy("REVIEW names only a verifier-owned violation: fix-completed skipped, no implementer run; three failed checks park the spec (exit 7), no gate pauses", () => {
      const root = scenario();
      stubFile(root, "check-run-conformance.rc", "1");
      stubFile(root, "check-run-conformance.json", REVIEW_FAIL);
      const r = run(root, ["--resume", "--from", "17", "--until", "17", "--max-attempts", "3"]);
      expect(r.status).toBe(7);
      expect(calls(root, 19)).toBe(0);
      expect(calls(root, 17)).toBe(3);
      const fixes = events(root).filter((e) => e.kind === "fix-completed");
      expect(fixes.length).toBeGreaterThanOrEqual(1);
      expect(fixes.every((e) => e.payload.skipped === true)).toBe(true);
      const j = runJson(root);
      expect(j.gate_id).toBe(""); // nothing is waiting for a human
      expect(j.status).toBe("stopped");
      expect(j.reason).toContain("needs attention");
      const na = text(root, "coordination/NeedsAttention.md");
      expect(na).toContain("## [open] SPEC-001 | loop");
      expect(na).toContain("REV-003");
      expect(na).toMatch(/- todo: .*kcc-run --from 17/);
      expect(r.stdout).toContain("needs attention: coordination/NeedsAttention.md - 1 item(s), 1 open");
      const dec = events(root).filter((e) => e.kind === "human-gate-decision" && e.payload.gate === "loop");
      expect(dec[0].payload).toMatchObject({ answered_by: "policy", answer: "needs-attention" });
      expect(events(root).some((e) => e.kind === "needs-attention" && e.payload.status === "open" && e.spec === "SPEC-001")).toBe(true);
    });
  });

  describe(`--silent --assume never stops for a human: a blocked bug (${dname})`, () => {
    heavy("is ruled by policy (the recommended option), FIX runs once with that ruling, and NeedsAttention.md records the decision", () => {
      const root = scenario();
      const f = putBug(root, "Bug-003", "blocked", true);
      const r = run(root, ["--resume", "--from", "19", "--until", "19"]);
      expect(r.status).toBe(0);
      expect(r.stdout).not.toContain("PAUSED");
      expect(calls(root, 19)).toBe(1);
      expect(prompts(root, 19)[0]).toContain("ruling by policy (revise)");
      expect(prompts(root, 19)[0]).toContain("recommended option");
      const t = readFileSync(f, "utf8");
      expect(t).toMatch(/\| major \| fixed \|/);
      expect(t).toContain("## Ruling");
      expect(runJson(root).gate_id).toBe("");
      const na = text(root, "coordination/NeedsAttention.md");
      expect(na).toContain("## [decided] SPEC-001 | ruling");
      expect(na).toContain("recommended option");
      expect(na).toMatch(/- links: coordination\/gates\/GATE-001\.md/);
      const dec = events(root).filter((e) => e.kind === "human-gate-decision" && e.payload.gate === "ruling");
      expect(dec.length).toBe(1);
      expect(dec[0].payload).toMatchObject({ answered_by: "policy", answer: "revise" });
      expect(dec[0].payload.note).toContain("recommended option");
      expect(text(root, "coordination/gates/GATE-001.md")).toContain("status: answered");
    });
  });
}
