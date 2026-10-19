import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { createLane, git, groupByOrder, isGitWorkspace, laneBranch, laneDir, laneMode, liveSyncLane, mergeLane, mergeWorktreeLane, mirrorRun, parseRoadmap, readySpecs, removeLane, scheduleSpecs, snapshot } from "../src/run/lanes";
import { applyPayload } from "../src/lock";
import { isWindows } from "../src/platform";

setDefaultTimeout(120000);
const temp = mkdtempSync(join(tmpdir(), "kcc-lanes-"));
afterAll(() => rmSync(temp, { recursive: true, force: true }));

const put = (root: string, rel: string, text: string): void => {
  mkdirSync(dirname(join(root, rel)), { recursive: true });
  writeFileSync(join(root, rel), text);
};
const read = (root: string, rel: string): string => readFileSync(join(root, rel), "utf8");

const ROADMAP = `# Roadmap

## Execution Plan
| Order | Spec | Delivery | Depends on | Lane | Est. tokens |
|--|--|--|--|--|--|
| 1 | [[SPEC-001-core/SPEC-001-core]] | core | None | A | n/a |
| 2 | [[SPEC-002-ledger/SPEC-002-ledger]] | ledger | SPEC-001 | A | n/a |
| 2 | [[SPEC-003-web/SPEC-003-web]] | web | SPEC-001 | B | n/a |
| 3 | [[SPEC-004-e2e/SPEC-004-e2e]] | e2e | SPEC-002, SPEC-003 | A | n/a |

## Optimisation Notes
- not a table row
`;

describe("roadmap", () => {
  test("rows and order groups are read from the Execution Plan table", () => {
    const rows = parseRoadmap(ROADMAP);
    expect(rows.map((r) => r.spec)).toEqual(["SPEC-001", "SPEC-002", "SPEC-003", "SPEC-004"]);
    expect(rows[3]!.dependsOn).toEqual(["SPEC-002", "SPEC-003"]);
    expect(groupByOrder(rows)).toEqual([["SPEC-001"], ["SPEC-002", "SPEC-003"], ["SPEC-004"]]);
  });
  test("no table means no rows", () => {
    expect(parseRoadmap("# nothing here")).toEqual([]);
  });
});

describe("merging a lane back", () => {
  const main = join(temp, "merge-main");
  const base = (): Record<string, string> => snapshot(main);
  test("setup", () => {
    put(main, "src/a.ts", "a1");
    put(main, "src/b.ts", "b1");
    put(main, "src/c.ts", "c1");
    put(main, "specs/specs.md", "index v1");
    put(main, "coordination/backchannel.jsonl", '{"id":"BC-00001","kind":"x"}\n{"id":"BC-00002","kind":"y"}\n');
  });

  test("a clean lane is applied, deletions included; run state is never copied", () => {
    const lane = createLane(main, "SPEC-009", false);
    put(lane.dir, "src/a.ts", "a2");
    put(lane.dir, "src/new.ts", "n");
    rmSync(join(lane.dir, "src/b.ts"));
    put(lane.dir, "coordination/run/run.json", "{}");
    put(lane.dir, "node_modules/x/index.js", "x");
    const m = mergeLane(main, lane.dir, lane.base);
    expect(m.conflicts).toEqual([]);
    expect(m.applied.sort()).toEqual(["src/a.ts", "src/new.ts"]);
    expect(m.deleted).toEqual(["src/b.ts"]);
    expect(read(main, "src/a.ts")).toBe("a2");
    expect(existsSync(join(main, "src/b.ts"))).toBe(false);
    expect(existsSync(join(main, "coordination/run/run.json"))).toBe(false);
    expect(existsSync(join(main, "node_modules"))).toBe(false);
  });

  test("a file changed in the lane and in main is a conflict and main keeps its version", () => {
    const lane = createLane(main, "SPEC-010", false);
    put(lane.dir, "src/c.ts", "c-lane");
    put(main, "src/c.ts", "c-main");
    const m = mergeLane(main, lane.dir, lane.base);
    expect(m.conflicts).toEqual(["src/c.ts"]);
    expect(read(main, "src/c.ts")).toBe("c-main");
  });

  test(".gitignore is merged as a set of rules, never a conflict (round 13: a clean skeleton ended on it)", () => {
    put(main, ".gitignore", "node_modules/\ndist/\n");
    const lane = createLane(main, "SPEC-013", false);
    expect(read(lane.dir, ".gitignore")).toContain(".kcc-lane/"); // the lane marker is in the lane copy only
    expect(lane.base[".gitignore"]).toBe(snapshot(main)[".gitignore"]); // and not in the base the merge compares against
    const m0 = mergeLane(main, lane.dir, lane.base);
    expect(m0.conflicts).toEqual([]);
    expect(m0.applied).toEqual([]); // an untouched lane .gitignore changes nothing in the workspace
    expect(read(main, ".gitignore")).toBe("node_modules/\ndist/\n");
    // the implementer adds rules in the lane while the workspace file also changed (another lane merged first)
    put(lane.dir, ".gitignore", read(lane.dir, ".gitignore") + "\n# app data\ndata/\n*.db\ndist/\n");
    put(main, ".gitignore", "node_modules/\ndist/\ncoverage/\n");
    const m = mergeLane(main, lane.dir, lane.base);
    expect(m.conflicts).toEqual([]);
    expect(m.applied).toEqual([".gitignore"]);
    const lines = read(main, ".gitignore").split("\n");
    expect(lines).toEqual(["node_modules/", "dist/", "coverage/", "", "# app data", "data/", "*.db", ""]); // new rules appended once, the marker never
    expect(read(main, ".gitignore")).not.toContain(".kcc-lane");
  });

  test("a clash on a shared index is skipped, not a conflict", () => {
    const lane = createLane(main, "SPEC-011", false);
    put(lane.dir, "specs/specs.md", "index lane");
    put(main, "specs/specs.md", "index main");
    const m = mergeLane(main, lane.dir, lane.base);
    expect(m.conflicts).toEqual([]);
    expect(m.sharedSkipped).toEqual(["specs/specs.md"]);
    expect(read(main, "specs/specs.md")).toBe("index main");
  });

  test("the lane's new backchannel events are appended with fresh ids", () => {
    const lane = createLane(main, "SPEC-012", false);
    writeFileSync(join(lane.dir, "coordination/backchannel.jsonl"), read(lane.dir, "coordination/backchannel.jsonl") + '{"id":"BC-00003","kind":"lane"}\n');
    put(main, "coordination/backchannel.jsonl", read(main, "coordination/backchannel.jsonl") + '{"id":"BC-00003","kind":"other-lane"}\n');
    const m = mergeLane(main, lane.dir, lane.base);
    expect(m.events).toBe(1);
    const lines = read(main, "coordination/backchannel.jsonl").trim().split("\n");
    expect(lines.map((l) => JSON.parse(l).id)).toEqual(["BC-00001", "BC-00002", "BC-00003", "BC-00004"]);
    expect(JSON.parse(lines[3]!).kind).toBe("lane");
  });
});

describe("dependency scheduling", () => {
  test("a spec is ready only when every spec it depends on is merged", () => {
    const rows = parseRoadmap(ROADMAP);
    expect(readySpecs(rows, {})).toEqual(["SPEC-001"]);
    const merged = { status: "merged" as const, dir: "" };
    expect(readySpecs(rows, { "SPEC-001": merged })).toEqual(["SPEC-002", "SPEC-003"]);
    expect(readySpecs(rows, { "SPEC-001": merged, "SPEC-002": merged, "SPEC-003": { status: "running", dir: "" } })).toEqual([]);
  });

  test("independent specs run at the same time, dependent ones wait, a slow spec does not hold back an unrelated one", async () => {
    const main = join(temp, "sched-main");
    // SPEC-003 is slow; SPEC-005 depends only on SPEC-002, so it must start before SPEC-003 finishes.
    const roadmap = ROADMAP.replace("| 3 | [[SPEC-004-e2e/SPEC-004-e2e]] | e2e | SPEC-002, SPEC-003 | A | n/a |",
      "| 3 | [[SPEC-004-e2e/SPEC-004-e2e]] | e2e | SPEC-002, SPEC-003 | A | n/a |"+String.fromCharCode(10)+"| 3 | [[SPEC-005-api2/SPEC-005-api2]] | api2 | SPEC-002 | C | n/a |");
    put(main, "specs/IDEA-001-demo-Specs/ROADMAP.md", roadmap);
    for (const s of ["SPEC-001-core", "SPEC-002-ledger", "SPEC-003-web", "SPEC-004-e2e", "SPEC-005-api2"]) put(main, `specs/IDEA-001-demo-Specs/${s}/${s}.md`, "# spec");
    const times: Record<string, [number, number]> = {};
    const code = await scheduleSpecs(main, {
      passthrough: ["--fasttrack"],
      maxParallel: 4,
      syncSeconds: 0.2,
      log: () => {},
      runDriver: async (dir, args) => {
        const spec = args[args.indexOf("--input") + 1]!;
        const t0 = Date.now();
        await Bun.sleep(spec === "SPEC-003" ? 1500 : 400);
        put(dir, `src/IDEA-001-demo/${spec}.txt`, spec);
        put(dir, `specs/IDEA-001-demo-Specs/${[...["SPEC-001-core", "SPEC-002-ledger", "SPEC-003-web", "SPEC-004-e2e", "SPEC-005-api2"]].find((s) => s.startsWith(spec))}/review.md`, "APPROVED");
        times[spec] = [t0, Date.now()];
        return 0;
      },
    });
    expect(code).toBe(0);
    for (const s of ["SPEC-001", "SPEC-002", "SPEC-003", "SPEC-004", "SPEC-005"]) {
      expect(existsSync(join(main, `src/IDEA-001-demo/${s}.txt`))).toBe(true);
      expect(existsSync(laneDir(main, s))).toBe(false); // merged lanes are removed
    }
    expect(read(main, "specs/IDEA-001-demo-Specs/SPEC-004-e2e/review.md")).toBe("APPROVED");
    const [a, b] = [times["SPEC-002"]!, times["SPEC-003"]!];
    expect(a[0] < b[1] && b[0] < a[1]).toBe(true); // 002 and 003 overlapped
    expect(times["SPEC-005"]![0]).toBeLessThan(times["SPEC-003"]![1]); // 005 did not wait for the unrelated 003
    expect(times["SPEC-004"]![0]).toBeGreaterThanOrEqual(Math.max(a[1], b[1])); // 004 waited for both
    const events = read(main, "coordination/backchannel.jsonl");
    expect(events).toContain("lane-started");
    expect(events).toContain("lane-merged");
  });

  test("a lane that stops leaves its dependents waiting and returns 4", async () => {
    const main = join(temp, "sched-stop");
    put(main, "specs/IDEA-001-demo-Specs/ROADMAP.md", ROADMAP);
    const code = await scheduleSpecs(main, {
      passthrough: [], maxParallel: 4, syncSeconds: 0.2, log: () => {},
      runDriver: async (_dir, args) => (args[args.indexOf("--input") + 1] === "SPEC-002" ? 4 : 0),
    });
    expect(code).toBe(4);
    const state = JSON.parse(read(main, "coordination/lanes.json"));
    expect(state["SPEC-002"].status).toBe("failed");
    expect(state["SPEC-003"].status).toBe("merged");
    expect(state["SPEC-004"]).toBeUndefined(); // never started: it depends on SPEC-002
    expect(existsSync(laneDir(main, "SPEC-002"))).toBe(true); // kept, so its gate can be answered
  });
});

describe("a lane that is busy does not crash the scheduler's snapshot", () => {
  // Round 8: vite/vitest write vitest.config.ts.timestamp-<n>-<hex>.mjs and delete it a moment later. The snapshot read
  // it, got ENOENT, and the whole `kcc run` died while the lane it supervised kept running, orphaned.
  test("transient bundler files are not part of a snapshot, and a missing folder is not an error", () => {
    const lane = join(temp, "busy-lane");
    put(lane, "src/api/app.ts", "export {};");
    put(lane, "src/api/vitest.config.ts.timestamp-1792143875985-65fde6ce734db.mjs", "x");
    const s = snapshot(lane);
    expect(Object.keys(s)).toEqual(["src/api/app.ts"]);
    expect(snapshot(join(temp, "no-such-lane"))).toEqual({});
  });
});

describe("the run shows what the lanes are doing", () => {
  // Round 8 and 9: run.json said "stopped (until 9)" at PREFLIGHT for hours while SPEC-001 was being built.
  test("while lanes run, the run is running at the earliest lane stage; when one needs attention it is stopped with the reason", () => {
    const main = join(temp, "mirror-main");
    const lane = join(temp, "mirror-lane");
    put(main, "coordination/run/run.json", JSON.stringify({ status: "stopped", reason: "until 9", state: "14", updated: "2026-01-01T00:00:00Z" }));
    put(lane, "coordination/run/run.json", JSON.stringify({ status: "running", state: "16" }));
    const state = { "SPEC-001": { status: "running", dir: lane } };
    mirrorRun(main, state, ["SPEC-001"]);
    let run = JSON.parse(read(main, "coordination/run/run.json"));
    expect(run).toMatchObject({ status: "running", reason: "specs running in lanes: SPEC-001", state: "16" });
    expect(run.updated).not.toBe("2026-01-01T00:00:00Z");
    mirrorRun(main, state, [], { status: "stopped", reason: "specs need attention: SPEC-001" });
    run = JSON.parse(read(main, "coordination/run/run.json"));
    expect(run).toMatchObject({ status: "stopped", reason: "specs need attention: SPEC-001" });
    expect(() => mirrorRun(join(temp, "no-run"), state, ["SPEC-001"])).not.toThrow();
  });
});

describe("a lane's work reaches the workspace while it runs", () => {
  test("src and the spec's results appear before the lane ends; a later edit of a synced file still syncs; a file the workspace changed is left alone", () => {
    const main = join(temp, "live-main");
    put(main, "README.md", "x");
    put(main, "specs/IDEA-001-x-Specs/SPEC-001-a/SPEC-001-a.md", "spec");
    const { dir: lane } = createLane(main, "SPEC-001", false);
    const sync = () => liveSyncLane(main, lane, "SPEC-001");
    put(lane, "src/IDEA-001-x/api/app.ts", "v1");
    put(lane, "TestResults/IDEA-001/SPEC-001/test-run-summary.md", "| T-001 | PASS |");
    sync();
    expect(read(main, "src/IDEA-001-x/api/app.ts")).toBe("v1"); // visible in the workspace mid-run
    expect(read(main, "TestResults/IDEA-001/SPEC-001/test-run-summary.md")).toContain("PASS");
    put(lane, "src/IDEA-001-x/api/app.ts", "v2");
    sync();
    expect(read(main, "src/IDEA-001-x/api/app.ts")).toBe("v2"); // the base advanced, so this is not a clash
    put(main, "README.md", "changed in the workspace");
    put(lane, "README.md", "changed in the lane");
    const r = sync();
    expect(r?.conflicts).toContain("README.md");
    expect(read(main, "README.md")).toBe("changed in the workspace");
  });
});

describe("worktree lanes in a git workspace (round 13)", () => {
  const main = join(temp, "wt-main");
  const g = (...a: string[]) => spawnSync("git", a, { cwd: main, encoding: "utf8" });
  const log = (): string[] => git(main, "log", "--format=%s").stdout.trim().split(/\r?\n/);
  test("setup: a repository with one commit, uncommitted work from the shared states, and ignored runtime files", () => {
    put(main, ".gitignore", "node_modules/\n.claude/\ncoordination/backchannel.jsonl\n");
    put(main, "README.md", "r1");
    g("init", "-q", "-b", "main"); g("config", "user.email", "t@example.com"); g("config", "user.name", "T"); g("config", "core.autocrlf", "false");
    g("add", "-A"); g("commit", "-q", "-m", "chore: base");
    put(main, "architecture/architecture.md", "# arch"); // written by ARCH, never committed by the driver
    put(main, "specs/IDEA-001-x-Specs/SPEC-001-a/SPEC-001-a.md", "spec");
    put(main, ".claude/agents/implementer.md", "agent"); // ignored, but a lane cannot run without it
    put(main, "coordination/backchannel.jsonl", '{"id":"BC-00001","kind":"x"}\n');
    expect(isGitWorkspace(main)).toBe(true);
  });

  test("a lane is a worktree on spec/SPEC-NNN cut from HEAD; the workspace's uncommitted work is committed first and the runtime files are copied", () => {
    const lane = createLane(main, "SPEC-001", false);
    expect(laneMode(lane.dir)).toBe("worktree");
    expect(log()[0]).toBe("SPEC-001: workspace state before the lane (kcc)");
    expect(git(lane.dir, "rev-parse", "--abbrev-ref", "HEAD").stdout.trim()).toBe(laneBranch("SPEC-001"));
    expect(read(lane.dir, "architecture/architecture.md")).toBe("# arch"); // the committed shared-state output is in the lane
    expect(read(lane.dir, ".claude/agents/implementer.md")).toBe("agent"); // the ignored harness folder was copied
    expect(read(lane.dir, "coordination/backchannel.jsonl")).toContain("BC-00001");
    expect(git(main, "status", "--porcelain").stdout.trim()).toBe(""); // the lane folder is excluded, not an untracked change
    expect(existsSync(join(lane.dir, ".gitignore"))).toBe(true);
    expect(read(lane.dir, ".gitignore")).not.toContain(".kcc-lane"); // no marker line in a tracked file any more
    removeLane(main, lane.dir);
    expect(existsSync(lane.dir)).toBe(false);
    expect(git(main, "worktree", "list").stdout).not.toContain("SPEC-001");
  });

  test("a finished lane merges with git: .gitignore edits on both sides are a union, disjoint files fast-forward, the worktree goes away", () => {
    const lane = createLane(main, "SPEC-002", false);
    put(lane.dir, "src/IDEA-001-x/api/app.ts", "v1");
    put(lane.dir, ".gitignore", read(lane.dir, ".gitignore") + "\n# app data\ndata/\n*.db\n");
    git(lane.dir, "add", "-A"); git(lane.dir, "commit", "-q", "-m", "SPEC-002 Story-001: app");
    put(lane.dir, "TestResults/IDEA-001/SPEC-002/test-run-summary.md", "| T-001 | PASS |"); // left uncommitted by the verifier
    put(main, ".gitignore", read(main, ".gitignore") + "coverage/\n"); // the workspace moved too
    const m = mergeWorktreeLane(main, lane.dir, "SPEC-002");
    expect(m.conflicts).toEqual([]);
    expect(m.applied).toEqual(expect.arrayContaining(["src/IDEA-001-x/api/app.ts", "TestResults/IDEA-001/SPEC-002/test-run-summary.md", ".gitignore"]));
    expect(read(main, "src/IDEA-001-x/api/app.ts")).toBe("v1");
    const gi = read(main, ".gitignore");
    for (const l of ["node_modules/", "coverage/", "data/", "*.db"]) expect(gi).toContain(l);
    expect(gi).not.toContain(".kcc-lane");
    expect(log()[0]).toBe("SPEC-002: merge lane spec/SPEC-002 (kcc)");
    expect(git(main, "status", "--porcelain").stdout.trim()).toBe("");
    removeLane(main, lane.dir);
    expect(existsSync(lane.dir)).toBe(false);
  });

  test("a real conflict aborts the merge, leaves the workspace as it was and names the file; the branch keeps the lane's work", () => {
    const lane = createLane(main, "SPEC-003", false);
    put(lane.dir, "README.md", "lane says");
    put(main, "README.md", "workspace says");
    const m = mergeWorktreeLane(main, lane.dir, "SPEC-003");
    expect(m.conflicts).toEqual(["README.md"]);
    expect(read(main, "README.md")).toBe("workspace says");
    expect(git(main, "status", "--porcelain").stdout.trim()).toBe(""); // no half-merged tree
    expect(git(main, "show", `${laneBranch("SPEC-003")}:README.md`).stdout).toBe("lane says"); // the branch has it for a merge by hand
    removeLane(main, lane.dir);
  });

  test("two lanes that both add rows to a shared index both merge", () => {
    put(main, "specs/specs.md", "# specs\n- SPEC-001\n");
    g("add", "-A"); g("commit", "-q", "-m", "chore: index");
    const a = createLane(main, "SPEC-004", false);
    const b = createLane(main, "SPEC-005", false);
    put(a.dir, "specs/specs.md", "# specs\n- SPEC-001\n- SPEC-004\n");
    put(b.dir, "specs/specs.md", "# specs\n- SPEC-001\n- SPEC-005\n");
    expect(mergeWorktreeLane(main, a.dir, "SPEC-004").conflicts).toEqual([]);
    expect(mergeWorktreeLane(main, b.dir, "SPEC-005").conflicts).toEqual([]);
    expect(read(main, "specs/specs.md")).toBe("# specs\n- SPEC-001\n- SPEC-004\n- SPEC-005\n");
    removeLane(main, a.dir); removeLane(main, b.dir);
  });

  test("the scheduler end to end in a git workspace: lanes are worktrees, merged lanes are gone, src arrives with the merge", async () => {
    const wsRoadmap = ROADMAP.replace(/SPEC-00(\d)-([a-z0-9]+)\/SPEC-00\d-[a-z0-9]+/g, "SPEC-00$1-$2/SPEC-00$1-$2");
    put(main, "specs/IDEA-001-demo-Specs/ROADMAP.md", wsRoadmap);
    for (const s of ["SPEC-001-core", "SPEC-002-ledger", "SPEC-003-web", "SPEC-004-e2e"]) put(main, `specs/IDEA-001-demo-Specs/${s}/${s}.md`, "# spec");
    g("add", "-A"); g("commit", "-q", "-m", "chore: roadmap");
    const code = await scheduleSpecs(main, {
      passthrough: ["--fasttrack"], maxParallel: 4, syncSeconds: 0.2, log: () => {},
      runDriver: async (dir, args) => {
        const spec = args[args.indexOf("--input") + 1]!;
        expect(laneMode(dir)).toBe("worktree");
        put(dir, `src/IDEA-001-demo/${spec}.txt`, spec);
        git(dir, "add", "-A"); git(dir, "commit", "-q", "-m", `${spec} Story-001: work`);
        put(dir, "specs/specs.md", read(dir, "specs/specs.md") + `- built ${spec}\n`); // left uncommitted, union-merged
        return 0;
      },
    });
    expect(code).toBe(0);
    for (const s of ["SPEC-001", "SPEC-002", "SPEC-003", "SPEC-004"]) {
      expect(read(main, `src/IDEA-001-demo/${s}.txt`)).toBe(s);
      expect(existsSync(laneDir(main, s))).toBe(false);
    }
    expect(git(main, "worktree", "list").stdout.trim().split(/\r?\n/).length).toBe(1); // only the workspace itself
    expect(read(main, "specs/specs.md").match(/- built SPEC-/g)?.length).toBe(4);
    expect(git(main, "status", "--porcelain").stdout.trim()).toBe("");
    expect(read(main, "coordination/backchannel.jsonl")).toContain("lane-merged");
  });
});
