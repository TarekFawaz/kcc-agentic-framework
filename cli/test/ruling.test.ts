import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { isWindows, runTool } from "../src/platform";

/**
 * Round 10 (BudgetPal, SPEC-001): a fix that needed a human ruling was retried three times, every TEST was a full
 * verification on the strongest model, and nothing capped the number of full passes. These tests drive kcc-run against the
 * stub harness (test/fixtures/stub-harness.sh) and prove, in both drivers:
 *  - a Bug with Status blocked opens the `ruling` gate at once: the implementer is not run, no attempt is used;
 *  - the ruling answers (revise, waive) act on the Bug file and the next prompt;
 *  - the first TEST is a full pass, a later one (after a CHANGES_NEEDED review) is scoped and routed at balanced / high;
 *  - a third full verifier pass is replaced by the loop gate, which lists the still-open bugs.
 */
setDefaultTimeout(900000);
const temp = mkdtempSync(join(tmpdir(), "kcc-ruling-"));
afterAll(() => rmSync(temp, { recursive: true, force: true }));
const STUB = join(import.meta.dir, "fixtures", "stub-harness.sh");

function workspace(name: string): string {
  const root = join(temp, name);
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
const calls = (root: string) => (existsSync(join(root, ".kcc-stub", "calls.log")) ? readFileSync(join(root, ".kcc-stub", "calls.log"), "utf8").trim().split(/\r?\n/) : []);
const callsOf = (root: string, state: number) => calls(root).filter((l) => new RegExp(`state=${state}\\b`).test(l)).length;
const prompts = (root: string) => (existsSync(join(root, ".kcc-stub", "prompts.log")) ? readFileSync(join(root, ".kcc-stub", "prompts.log"), "utf8").trim().split(/\r?\n/) : []);
const lastPrompt = (root: string, state: number) => prompts(root).filter((l) => l.startsWith(`KCC run state ${state} `)).pop() ?? "";
const bc = (root: string) => readFileSync(join(root, "coordination", "backchannel.jsonl"), "utf8").trim().split(/\r?\n/).filter(Boolean).map((l) => JSON.parse(l));
const runJson = (root: string) => JSON.parse(readFileSync(join(root, "coordination", "run", "run.json"), "utf8"));
const ps = (root: string, args: string[]) => runTool(root, "kcc-run", args, { capture: true });
const sh = (root: string, args: string[]) => {
  const r = spawnSync("bash", [join(root, ".KCC", "tools", "kcc-run.sh"), ...args, "--repo-root", root], { cwd: root, encoding: "utf8" });
  return { status: r.status ?? 1, stdout: (r.stdout ?? "") + (r.stderr ?? "") };
};
const FT = ["--input", "a tiny app", "--silent", "--assume", "--fasttrack"];
const drv = isWindows ? ps : sh;
// The scenarios run in each driver; the preparation (IDEA .. IMPLEMENT) always uses the OS driver, then the scenario switches.
// Git Bash forks are so slow on Windows (one TEST state takes minutes there) that the bash driver only proves the gate on Windows;
// every scenario runs in the OS driver, and in bash on Linux and macOS.
const drivers: [string, typeof sh, boolean][] = isWindows ? [["powershell", ps, true], ["bash", sh, false]] : [["bash", sh, true]];

const specDir = (root: string): string => {
  const dir = readdirSync(join(root, "specs")).find((d) => d.startsWith("IDEA-"))!;
  const spec = readdirSync(join(root, "specs", dir)).find((d) => d.startsWith("SPEC-"))!;
  return join(root, "specs", dir, spec);
};
const bugText = (status: string, severity = "major", ruling = true) => `# Bug-003: the tool cannot read the lockfile

| Type | Parent | Source | Severity | Status | Story / AC | Regression test | Evidence |
|--|--|--|--|--|--|--|--|
| Bug | [[../SPEC-001]] | verifier | ${severity} | ${status} | Story-001 / AC-1 | T-001 | none |

## Impacted Files
- src/IDEA-001-demo/app.ts
${ruling ? `
## Ruling needed
- Blocker: quality-gate cannot read a workspace-root lockfile.
- Options: (A) move the lockfile into src/ (B) edit the framework tool (C) waive with a note.
- Recommended: A - smallest change, no framework edit.
` : ""}`;
const placeBug = (root: string, status: string, severity = "major", ruling = true): string => {
  const f = join(specDir(root), "Backlog", "Bug-003-lockfile.md");
  mkdirSync(join(specDir(root), "Backlog"), { recursive: true });
  writeFileSync(f, bugText(status, severity, ruling));
  return f;
};
// The preparation runs --silent --assume (nobody answers prompts). These scenarios are about the BLOCKING gates, which a run without
// --silent --assume keeps (a silent run never pauses; see verdictloop.test.ts), so the run is switched to non-silent here.
const prepared = (name: string): string => {
  const root = workspace(name);
  expect(drv(root, [...FT, "--until", "15"]).status).toBe(0);
  const rj = join(root, "coordination", "run", "run.json");
  writeFileSync(rj, readFileSync(rj, "utf8").replace(/"silent": "1"/, '"silent": "0"').replace(/"assume": "1"/, '"assume": "0"'));
  return root;
};

for (const [dname, run, every] of drivers) {
  const scenario = every ? test : test.skip;
  describe(`a blocked Bug opens the ruling gate at once (${dname})`, () => {
    test("no implementer run, no attempt used, the gate names the Bug and quotes the ruling section; a run without --silent --assume waits for the human", () => {
      const root = prepared(`blocked-${dname}`);
      placeBug(root, "blocked");
      const before = callsOf(root, 19);
      const r = run(root, ["--resume", "--from", "19", "--until", "19"]);
      expect(r.status).toBe(4);
      expect(r.stdout).toContain("PAUSED at state 19");
      expect(r.stdout).toContain("gate ruling");
      expect(r.stdout).toMatch(/revise \| waive \| escalate \| abort/);
      expect(callsOf(root, 19)).toBe(before);
      expect(r.stdout).not.toContain("BUG-OPEN");
      expect(r.stdout).not.toContain("FAIL   state 19");
      const j = runJson(root);
      expect(j.gate_name).toBe("ruling");
      expect(j.gate_kind).toBe("ruling");
      expect(j.gate_answers).toBe("revise/waive/escalate/abort");
      expect(j.attempts).not.toContain("19:");
      const g = readFileSync(join(root, "coordination", "gates", "GATE-001.md"), "utf8");
      expect(g).toContain("kind: ruling");
      expect(g).toContain("Bug-003");
      expect(g).toContain("quality-gate cannot read a workspace-root lockfile");
      expect(g).toContain("Recommended: A");
      const ev = bc(root).filter((e) => e.kind === "human-gate-triggered").pop();
      expect(ev.payload.kind).toBe("ruling");
    });

    scenario("waive records the Bug as wontfix and the state completes without an implementer", () => {
      const root = prepared(`waive-${dname}`);
      const f = placeBug(root, "blocked");
      expect(run(root, ["--resume", "--from", "19", "--until", "19"]).status).toBe(4);
      const r = run(root, ["--answer", "waive", "--note", "accepted: the tool limit is a known gap"]);
      expect(r.status).toBe(0);
      const t = readFileSync(f, "utf8");
      expect(t).toMatch(/\| major \| wontfix \|/);
      expect(t).toContain("## Ruling");
      expect(t).toContain("`waive`");
      expect(callsOf(root, 19)).toBe(0);
    });

    scenario("revise reopens the Bug, hands the human's ruling to the implementer once, and the Bug is fixed", () => {
      const root = prepared(`revise-${dname}`);
      const f = placeBug(root, "blocked");
      expect(run(root, ["--resume", "--from", "19", "--until", "19"]).status).toBe(4);
      const r = run(root, ["--answer", "revise", "--note", "take option A and move the lockfile"]);
      expect(r.status).toBe(0);
      expect(callsOf(root, 19)).toBe(1);
      expect(lastPrompt(root, 19)).toContain("human ruling (revise): take option A and move the lockfile");
      const t = readFileSync(f, "utf8");
      expect(t).toMatch(/\| major \| fixed \|/); // reopened to open, then the stub implementer closed it
      expect(t).toContain("`revise`");
    });

    scenario("an open Bug next to a blocked one is still fixed first; the blocked one then opens the gate (no BUG-OPEN retry loop)", () => {
      const root = prepared(`mixed-${dname}`);
      placeBug(root, "blocked");
      const f2 = join(specDir(root), "Backlog", "Bug-004-other.md");
      writeFileSync(f2, bugText("open", "minor", false).replace("Bug-003", "Bug-004"));
      const r = run(root, ["--resume", "--from", "19", "--until", "19"]);
      expect(r.status).toBe(4);
      expect(callsOf(root, 19)).toBe(1); // the open one was fixed ...
      expect(readFileSync(f2, "utf8")).toMatch(/\| minor \| fixed \|/);
      expect(runJson(root).gate_name).toBe("ruling"); // ... and the blocked one needs the human
    });
  });

  describe(`TEST: a full pass first, a scoped re-verification after (${dname})`, () => {
    const review = (verdict: string) => `---\nspec-id: SPEC-001\nstatus: changes-needed\nverdict: ${verdict}\ncommit: abc1234def5678\n---\n# SPEC-001 Verification Report\n\n## Verdict\n**${verdict}**\n`;
    scenario("the first TEST prompt asks for the full pass; once a CHANGES_NEEDED review exists the next one is scoped, routed balanced / high, and says so", () => {
      const root = prepared(`scoped-${dname}`);
      const first = run(root, ["--resume", "--from", "16", "--until", "16", "--max-attempts", "1"]);
      expect([0, 4]).toContain(first.status);
      const p1 = lastPrompt(root, 16);
      expect(p1).toContain("FULL VERIFICATION PASS 1 of at most 2");
      expect(p1).not.toContain("RE-VERIFICATION MODE");
      writeFileSync(join(specDir(root), "review.md"), review("CHANGES_NEEDED"));
      const second = run(root, ["--resume", "--from", "16", "--until", "16", "--max-attempts", "1"]);
      expect([0, 4]).toContain(second.status);
      const p2 = lastPrompt(root, 16);
      expect(p2).toContain("RE-VERIFICATION MODE");
      expect(p2).toContain("Re-verify only");
      expect(p2).toContain("abc1234def5678");
      expect(p2).toContain("quality-gate and check-traceability");
      expect(p2).toContain("Copy every other verdict row from the previous review.md unchanged");
      expect(p2).not.toContain("FULL VERIFICATION PASS");
      const sel = bc(root).filter((e) => e.kind === "model-selected" && e.payload.agent === "verifier");
      expect(sel.length).toBe(2);
      expect(sel[0].payload.pass).toBe("full");
      expect(sel[1].payload.pass).toBe("scoped");
      expect(sel[1].payload.tier).not.toBe("strong");
      expect(["low", "medium", "high"]).toContain(sel[1].payload.effort);
      expect(sel[1].payload.reasons).not.toContain("attempt");
    });

    scenario("the verifier is routed the same on a retry: no attempt escalation", () => {
      const root = prepared(`retry-${dname}`);
      // TEST fails its check, goes to FIX, comes back with the attempt counter at 1, 2: dispatches 2 and 3 are retries.
      const r = run(root, ["--resume", "--from", "16", "--until", "16", "--max-attempts", "3"]);
      expect([0, 4]).toContain(r.status);
      const sel = bc(root).filter((e) => e.kind === "model-selected" && e.payload.agent === "verifier");
      if (sel.length >= 2) {
        for (const e of sel) expect(String(e.payload.reasons)).not.toContain("attempt");
        expect(new Set(sel.map((e) => `${e.payload.tier}/${e.payload.effort}`)).size).toBe(1);
      }
    });
  });

  describe(`at most two full verifier passes per spec (${dname})`, () => {
    scenario("the third full pass is replaced by the loop gate, which lists the open bugs; revise grants exactly one more", () => {
      const root = prepared(`cap-${dname}`);
      // Two Bug items, one blocked: they are still open when the cap is reached. (minor: they do not fail the TEST check.)
      placeBug(root, "blocked", "minor");
      const f2 = join(specDir(root), "Backlog", "Bug-004-other.md");
      writeFileSync(f2, bugText("open", "major", false).replace("Bug-003", "Bug-004"));
      let r = run(root, ["--resume", "--from", "16", "--until", "16", "--max-attempts", "1"]);
      expect(r.status).toBe(4);
      expect(callsOf(root, 16)).toBe(1);
      r = run(root, ["--answer", "revise", "--max-attempts", "1"]);
      expect(r.status).toBe(4);
      expect(callsOf(root, 16)).toBe(2);
      r = run(root, ["--answer", "revise", "--max-attempts", "1"]);
      expect(r.status).toBe(4);
      expect(callsOf(root, 16)).toBe(2); // no third verifier
      const j = runJson(root);
      expect(j.gate_name).toBe("loop");
      const g = readFileSync(join(root, "coordination", "gates", `${j.gate_id}.md`), "utf8");
      expect(g).toContain("full pass number 3");
      expect(g).toContain("at most 2 full verifier passes");
      expect(g).toContain("Bug-003 (minor, blocked)");
      expect(g).toContain("Bug-004 (major, open)");
      expect(r.stdout).toContain("PAUSED at state 16");
      r = run(root, ["--answer", "revise", "--note", "one more, the human insists", "--max-attempts", "1"]);
      expect([0, 4]).toContain(r.status);
      expect(callsOf(root, 16)).toBe(3);
    });
  });
}

describe("check-run-conformance -Scope bugs: a blocked Bug is its own finding", () => {
  const SPEC = `---
id: SPEC-001
title: Walking skeleton
status: Draft
---
# SPEC-001: Walking skeleton

| Priority | Category | Status | Wave | Depends on | Blocks | Index |
|--|--|--|--|--|--|--|
| P1 | Feature | Draft | 1 | None | None | none |

## Backlog
| Key | Type | Title | Status | Wave |
|--|--|--|--|--|
| Bug-003 | Bug | lockfile | Draft | 1 |
`;
  const conformance = (root: string, which: "bash" | "os") => {
    if (which === "os") {
      const r = runTool(root, "check-run-conformance", ["--repo-root", root, "--scope", "bugs", "--spec", "SPEC-001", "--json"], { capture: true });
      return { rc: r.status, out: r.stdout };
    }
    const r = spawnSync("bash", [join(root, ".KCC", "tools", "check-run-conformance.sh"), "--repo-root", root, "--scope", "bugs", "--spec", "SPEC-001", "--json"], { cwd: root, encoding: "utf8" });
    return { rc: r.status ?? 1, out: r.stdout ?? "" };
  };
  const ids = (out: string) => [...out.matchAll(/"id"\s*:\s*"(BUG-\d+)"/g)].map((m) => m[1]);
  const build = (name: string, status: string, ruling: boolean): string => {
    const root = join(temp, name);
    applyPayload(root);
    const d = join(root, "specs", "IDEA-001-demo-Specs", "SPEC-001-skeleton");
    mkdirSync(join(d, "Backlog"), { recursive: true });
    writeFileSync(join(d, "SPEC-001-skeleton.md"), SPEC);
    writeFileSync(join(d, "Backlog", "Bug-003-lockfile.md"), bugText(status, "major", ruling));
    return root;
  };
  for (const which of (isWindows ? ["os", "bash"] : ["bash"]) as ("bash" | "os")[]) {
    test(`blocked with a ruling section: BUG-006 (error, human) quoting the options, not BUG-002 or BUG-OPEN (${which})`, () => {
      const root = build(`conf-blocked-${which}`, "blocked", true);
      const r = conformance(root, which);
      expect(r.rc).toBe(1);
      expect(ids(r.out)).toEqual(["BUG-006"]);
      const j = JSON.parse(r.out.slice(r.out.indexOf("{")));
      const v = j.violations.find((x: any) => x.id === "BUG-006");
      expect(v.severity).toBe("error");
      expect(v.fix_owner).toBe("human");
      expect(v.message).toContain("needs a human ruling");
      expect(v.message).toContain("Recommended: A");
    });
    test(`blocked without a ruling section adds BUG-007 for the implementer; open and wontfix are not blocked (${which})`, () => {
      const bare = conformance(build(`conf-bare-${which}`, "blocked", false), which);
      expect(ids(bare.out).sort()).toEqual(["BUG-006", "BUG-007"]);
      expect(JSON.parse(bare.out.slice(bare.out.indexOf("{"))).violations.find((x: any) => x.id === "BUG-007").fix_owner).toBe("implementer");
      expect(ids(conformance(build(`conf-open-${which}`, "open", false), which).out)).toEqual([]);
      expect(ids(conformance(build(`conf-wontfix-${which}`, "wontfix", false), which).out)).toEqual([]);
    });
  }
});
