import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { createLane, groupByOrder, laneDir, mergeLane, mirrorRun, parseRoadmap, readySpecs, scheduleSpecs, snapshot } from "../src/run/lanes";
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
