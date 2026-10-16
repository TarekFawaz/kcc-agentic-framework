import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { isWindows, runTool } from "../src/platform";

/**
 * The lifecycle itself, run by kcc-run against a stub harness (test/fixtures/stub-harness.sh) that writes
 * what a real orchestrator would, or deliberately does not. Proves: the fast-track table is used and has no
 * budget/ROI/critic states, the order of states, that an empty state fails its exit check and pauses at the
 * loop gate instead of passing, that over-production in ARCH is drift, that a wave that wrote nothing fails,
 * and that a paused run resumes. Both drivers run: PowerShell (through runTool on Windows) and bash.
 */
setDefaultTimeout(600000);
const temp = mkdtempSync(join(tmpdir(), "kcc-life-"));
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
const mode = (root: string, m: string) => writeFileSync(join(root, ".kcc-stub", "mode"), m);
const calls = (root: string) => (existsSync(join(root, ".kcc-stub", "calls.log")) ? readFileSync(join(root, ".kcc-stub", "calls.log"), "utf8").trim().split(/\r?\n/) : []);
const events = (root: string) => readFileSync(join(root, "coordination", "backchannel.jsonl"), "utf8").trim().split(/\r?\n/).filter(Boolean).map((l) => JSON.parse(l).kind as string);
const runJson = (root: string) => JSON.parse(readFileSync(join(root, "coordination", "run", "run.json"), "utf8"));
const ps = (root: string, args: string[]) => runTool(root, "kcc-run", args, { capture: true });
const sh = (root: string, args: string[]) => {
  const r = spawnSync("bash", [join(root, ".KCC", "tools", "kcc-run.sh"), ...args, "--repo-root", root], { cwd: root, encoding: "utf8" });
  return { status: r.status ?? 1, stdout: (r.stdout ?? "") + (r.stderr ?? "") };
};
const FT = ["--input", "a tiny app", "--silent", "--assume", "--fasttrack"];
// Real runs use the driver of the OS (PowerShell on Windows, where Git Bash forks are too slow for a
// multi-state run); the dry runs below exercise both drivers everywhere bash exists.
const drv = isWindows ? ps : sh;
const states = (out: string) => [...out.matchAll(/^\[(?:skip\] )?(?:\[)?(\d+)\]? state (\d+) ([A-Z0-9-]+)/gm)].map((m) => `${m[2]} ${m[3]}`);

describe("state tables", () => {
  const root = workspace("tables");
  test("--fasttrack runs its own table: no ROI, CONFIRM, ARCH-GATE, BUDGET or WINDOWS states, in both drivers", () => {
    const want = ["0 REPO", "1 IDEA", "4 BRIEFS", "5 ASK", "6 ARCH", "9 SPECS", "14 PREFLIGHT", "15 IMPLEMENT", "19 FIX", "16 TEST", "17 REVIEW", "18 CLOSE"];
    const a = sh(root, [...FT, "--dry-run"]);
    expect(a.status).toBe(0);
    expect(states(a.stdout)).toEqual(want);
    if (isWindows) expect(states(ps(root, [...FT, "--dry-run"]).stdout)).toEqual(want);
  });
  test("without --fasttrack the full table is unchanged", () => {
    const a = sh(root, ["--input", "a tiny app", "--silent", "--assume", "--dry-run"]);
    const got = states(a.stdout);
    expect(got[0]).toBe("0 REPO");
    expect(got).toContain("2 ROI");
    expect(got).toContain("8 BUDGET-0");
    expect(got[got.length - 1]).toBe("18 CLOSE");
  });
});

describe("fast track, happy path", () => {
  const root = workspace("happy");
  test("runs IDEA -> BRIEFS -> ASK -> ARCH -> SPECS -> PREFLIGHT -> IMPLEMENT with one dispatch per state and no human gate", () => {
    const r = drv(root, [...FT, "--until", "15"]);
    expect(r.status).toBe(0);
    expect(r.stdout).toMatch(/-?-?Until 15 reached/i);
    const c = calls(root).map((l) => /state=(\d+)/.exec(l)![1]);
    expect(c).toEqual(["1", "4", "5", "6", "9", "15"]); // REPO and PREFLIGHT pass on their checks alone
    const ev = events(root);
    expect(ev).toEqual(expect.arrayContaining(["fasttrack-approved", "idea-interrogation-completed", "specialist-brief-created", "architecture-pass-complete", "spec-created", "implement-completed"]));
    expect(ev).not.toContain("human-gate-triggered");
    expect(ev.indexOf("spec-created")).toBeGreaterThan(ev.indexOf("architecture-pass-complete"));
    expect(existsSync(join(root, "src", "IDEA-001-demo", "app.ts"))).toBe(true);
    expect(runJson(root).status).toBe("stopped");
  });
  test("the dashboard built from that run shows the fast-track stages and their times", () => {
    const d = runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
    expect(d.status).toBe(0);
    const html = readFileSync(join(root, "dashboard", "index.html"), "utf8");
    const data = JSON.parse(html.match(/<script id="kcc-data" type="application\/json">([\s\S]*?)<\/script>/)![1]!);
    expect(data.states.map((s: any) => s.id)).toEqual([0, 1, 4, 5, 6, 9, 14, 15, 19, 16, 17, 18]);
    expect(data.runLogs.length).toBe(6);
    expect(data.runLogs.every((l: any) => l.started && l.ended)).toBe(true);
  });
});

describe("fast track refuses empty work", () => {
  test("an IDEA that wrote nothing fails its check three times, then pauses at the loop gate; revise with real work continues", () => {
    const root = workspace("empty-idea");
    mode(root, "empty-idea");
    const r = drv(root, [...FT, "--until", "4"]);
    expect(r.status).toBe(4);
    expect(r.stdout).toContain("FILE-001");
    expect(r.stdout).toContain("PAUSED at state 1");
    expect(calls(root).length).toBe(3);
    expect(events(root)).toContain("human-gate-triggered");
    mode(root, "happy");
    const r2 = drv(root, ["--answer", "revise"]);
    expect(r2.status).toBe(0);
    expect(r2.stdout).toContain("done   state 1 IDEA");
    expect(r2.stdout).toMatch(/-?-?Until 4 reached/i);
  });
  test("an architecture pass that writes ADR files under fast track is drift, not a pass", () => {
    const root = workspace("over-arch");
    mode(root, "over-arch");
    const r = drv(root, [...FT, "--until", "6"]);
    expect(r.status).toBe(4);
    expect(r.stdout).toContain("ARCH-FT-007");
  });
  test("a wave that changed none of its declared files fails (WAVE-004)", () => {
    const root = workspace("empty-wave");
    const ok = drv(root, [...FT, "--until", "9"]);
    expect(ok.status).toBe(0);
    mode(root, "empty-wave");
    const r = drv(root, ["--resume"]);
    expect(r.status).toBe(4);
    expect(r.stdout).toContain("WAVE-004");
  });
});

describe("the FIX state (a failed TEST or REVIEW sends the spec back to the implementer)", () => {
  const bug = (status: string) => `# Bug-001: stale assertion

| Type | Parent | Source | Severity | Status | Story / AC | Regression test | Evidence |
|--|--|--|--|--|--|--|--|
| Bug | [[../SPEC-001]] | verifier | major | ${status} | Story-001 / AC-1 | T-001 | none |

## Impacted Files
- src/IDEA-001-demo/app.ts
`;
  const place = (root: string, status: string): string => {
    const dir = readdirSync(join(root, "specs")).find((d) => d.startsWith("IDEA-"))!;
    const spec = readdirSync(join(root, "specs", dir)).find((d) => d.startsWith("SPEC-"))!;
    const f = join(root, "specs", dir, spec, "Backlog", "Bug-001-stale.md");
    mkdirSync(join(root, "specs", dir, spec, "Backlog"), { recursive: true });
    writeFileSync(f, bug(status));
    return f;
  };
  const fixCalls = (root: string) => calls(root).filter((l) => /state=19/.test(l)).length;

  test("with no open Bug the state passes on its check alone: the implementer is not dispatched", () => {
    const root = workspace("fix-none");
    expect(drv(root, [...FT, "--until", "15"]).status).toBe(0);
    const r = drv(root, ["--resume", "--until", "19"]);
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("done   state 19 FIX SPEC-001 (exit check already passes)");
    expect(fixCalls(root)).toBe(0);
  });
  test("an open Bug sends the implementer, which closes it; the check then passes", () => {
    const root = workspace("fix-open");
    expect(drv(root, [...FT, "--until", "15"]).status).toBe(0);
    const f = place(root, "open");
    const r = drv(root, ["--resume", "--from", "19", "--until", "19"]);
    expect(r.status).toBe(0);
    expect(fixCalls(root)).toBe(1);
    expect(readFileSync(f, "utf8")).toContain("| fixed |");
  });
  test("a Bug the implementer leaves open fails BUG-OPEN and, after the attempts, pauses at the loop gate", () => {
    const root = workspace("fix-stuck");
    expect(drv(root, [...FT, "--until", "15"]).status).toBe(0);
    place(root, "open");
    mode(root, "no-fix");
    const r = drv(root, ["--resume", "--from", "19", "--until", "19"]);
    expect(r.status).toBe(4);
    expect(r.stdout).toContain("BUG-OPEN");
    expect(r.stdout).toContain("Bug-001");
  });
  test("TEST and REVIEW go to FIX on failure, in the table both drivers read", () => {
    const t = JSON.parse(readFileSync(join(import.meta.dir, "..", "..", ".KCC", "kernel", "auto-states-fasttrack.json"), "utf8")).states as any[];
    expect(t.find((s) => s.name === "TEST").on_fail_goto).toBe(19);
    expect(t.find((s) => s.name === "REVIEW").on_fail_goto).toBe(19);
    expect(t.map((s) => s.name).slice(7, 10)).toEqual(["IMPLEMENT", "FIX", "TEST"]);
  });
});
