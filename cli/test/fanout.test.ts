import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { createLane, fanoutSpecs, fanoutStates, laneDir, scheduleSpecs } from "../src/run/lanes";
import { payloadFiles } from "../src/payload";
import { isWindows, runTool } from "../src/platform";

/**
 * Writing and planning the specs: the SPECS state writes only the split; WRITE (a spec-writer per spec) and PLAN (a planner
 * per spec) are fan-out states. `kcc run` runs each of them for all specs at the same time, in lanes; the bare driver does
 * them spec by spec. Round 10: one spec-writer was told both "do it yourself" and "plan every spec with subagents", wrote no
 * plan, and the state took 27 minutes for 5 specs.
 */
setDefaultTimeout(600000);
const temp = mkdtempSync(join(tmpdir(), "kcc-fanout-"));
afterAll(() => rmSync(temp, { recursive: true, force: true }));
const STUB = join(import.meta.dir, "fixtures", "stub-harness.sh");
const table = (name: string): any[] => JSON.parse(payloadFiles().get(`kernel/${name}`)!.toString("utf8")).states;
const put = (root: string, rel: string, text: string): void => {
  mkdirSync(join(root, rel, ".."), { recursive: true });
  writeFileSync(join(root, rel), text);
};
const read = (root: string, rel: string): string => readFileSync(join(root, rel), "utf8");

describe("the state table", () => {
  const ft = table("auto-states-fasttrack.json");
  test("SPECS writes the split only: no plan, no plan check, no instruction to spawn planners", () => {
    const s = ft.find((x) => x.name === "SPECS");
    expect(s.command).toContain("--split-only");
    expect(s.command).not.toContain("/spec-plan");
    expect(s.command).not.toContain("plan every spec");
    const check = JSON.stringify(s.check);
    expect(check).toBe('{"tool":"internal:roadmap-specs"}'); // no `-Scope plan`, no `then`
  });
  test("WRITE and PLAN are per-spec fan-out states, each run by its own agent, each with its own per-spec exit check", () => {
    const names = ft.map((x) => x.name);
    expect(names.slice(names.indexOf("SPECS"), names.indexOf("PREFLIGHT"))).toEqual(["SPECS", "WRITE", "PLAN"]);
    const w = ft.find((x) => x.name === "WRITE");
    const p = ft.find((x) => x.name === "PLAN");
    expect([w.scope, w.fanout, w.agent_fasttrack, w.id]).toEqual(["spec", true, "spec-writer", 10]);
    expect([p.scope, p.fanout, p.agent_fasttrack, p.id]).toEqual(["spec", true, "planner", 11]);
    expect(w.check.args).toEqual(["-Scope", "specs", "-Spec", "{SPEC}", "-RunProfile", "fasttrack"]);
    expect(p.check.args).toEqual(["-Scope", "plan", "-Spec", "{SPEC}", "-RunProfile", "fasttrack"]);
    expect(p.command).toBe("/spec-plan {SPEC} --fasttrack {depthlevel}");
  });
  test("the full table fans out PLAN only (its BUDGET-P gate stays per spec)", () => {
    expect(table("auto-states.json").filter((x) => x.fanout).map((x) => x.name)).toEqual(["PLAN"]);
  });
  test("the router gives the planner the balanced tier at high effort on the first attempt; a retry keeps the tier and never goes above high (round 11)", () => {
    const root = join(temp, "route");
    applyPayload(root);
    const route = (attempt: string) => runTool(root, "kcc-route", ["--repo-root", root, "--agent", "planner", "--attempt", attempt, "--harness", "claude"], { capture: true }).stdout.split("\t");
    expect(route("1").slice(0, 3)).toEqual(["balanced", "claude-sonnet-5-5", "high"]);
    const retry = route("2");
    expect(retry.slice(0, 3)).toEqual(["balanced", "claude-sonnet-5-5", "high"]);
    expect(retry[3]).toBe("agent default: balanced / high; attempt 2: effort stays high, tier unchanged for planning");
  });
  test("the scheduler reads the fan-out states from the table the run uses", () => {
    const root = join(temp, "route");
    expect(fanoutStates(root, true)).toMatchObject({ after: 14 });
    expect(fanoutStates(root, true).states.map((s) => s.name)).toEqual(["WRITE", "PLAN"]);
    expect(fanoutStates(root, false).states.map((s) => s.name)).toEqual(["PLAN"]);
    expect(fanoutStates(root, false).after).toBe(12);
  });
});

describe("kcc run schedules a fan-out state for all specs at the same time", () => {
  const ROADMAP = `# Roadmap
## Execution Plan
| Order | Spec | Delivery | Depends on | Lane |
|--|--|--|--|--|
| 1 | [[SPEC-001-a/SPEC-001-a|SPEC-001]] | a | None | A |
| 2 | [[SPEC-002-b/SPEC-002-b|SPEC-002]] | b | SPEC-001 | A |
| 3 | [[SPEC-003-c/SPEC-003-c|SPEC-003]] | c | SPEC-002 | A |
`;
  const main = (name: string): string => {
    const m = join(temp, name);
    put(m, "specs/IDEA-001-demo-Specs/ROADMAP.md", ROADMAP);
    for (const s of ["SPEC-001-a", "SPEC-002-b", "SPEC-003-c"]) put(m, `specs/IDEA-001-demo-Specs/${s}/${s}.md`, "# stub");
    return m;
  };
  const opts = (extra: object) => ({ passthrough: ["--fasttrack"], maxParallel: 3, syncSeconds: 0.2, log: () => {}, ...extra });

  test("a chain of Depends on does not serialise them: three drivers overlap, each gets --until <state> and no --from", async () => {
    const m = main("sched-par");
    const t: Record<string, [number, number]> = {};
    const argv: Record<string, string[]> = {};
    const t0 = Date.now();
    const code = await scheduleSpecs(m, {
      ...opts({}), until: 11, independent: true, fanout: "PLAN",
      runDriver: async (dir, args) => {
        const spec = args[args.indexOf("--input") + 1]!;
        argv[spec] = args;
        const a = Date.now();
        await Bun.sleep(1200);
        put(dir, `specs/IDEA-001-demo-Specs/${spec}-${{ "SPEC-001": "a", "SPEC-002": "b", "SPEC-003": "c" }[spec]}/plan.md`, "plan");
        t[spec] = [a, Date.now()];
        return 0;
      },
    });
    expect(code).toBe(0);
    expect(Date.now() - t0).toBeLessThan(3000); // the sum is 3.6 s
    const all = Object.values(t);
    expect(Math.max(...all.map((x) => x[0]))).toBeLessThan(Math.min(...all.map((x) => x[1]))); // all three ran at once
    for (const a of Object.values(argv)) {
      expect(a.slice(a.indexOf("--until"), a.indexOf("--until") + 2)).toEqual(["--until", "11"]);
      expect(a).not.toContain("--from");
    }
    for (const s of ["001-a", "002-b", "003-c"]) expect(existsSync(join(m, `specs/IDEA-001-demo-Specs/SPEC-${s}/plan.md`))).toBe(true); // merged
    expect(JSON.parse(read(m, "coordination/lanes.json"))).toEqual({}); // a fan-out state keeps no lane state of its own
  });

  test("--max-parallel does not bound a fan-out state (all specs at once); --max-fanout N does", async () => {
    const peakOf = async (name: string, extra: object): Promise<number> => {
      const m = main(name);
      let now = 0;
      let peak = 0;
      const code = await scheduleSpecs(m, {
        ...opts({ maxParallel: 1, ...extra }), until: 11, independent: true, fanout: "PLAN",
        runDriver: async () => {
          peak = Math.max(peak, ++now);
          await Bun.sleep(300);
          now--;
          return 0;
        },
      });
      expect(code).toBe(0);
      return peak;
    };
    expect(await peakOf("sched-nolimit", {})).toBe(3); // maxParallel 1 is ignored here
    expect(await peakOf("sched-pool", { maxFanout: 2 })).toBe(2);
  });

  test("six specs: all six start before the first one ends, whatever --max-parallel says; the build lanes stay bounded by it", async () => {
    const rows = [1, 2, 3, 4, 5, 6].map((n) => `| ${n} | SPEC-00${n} | s | None | A |`).join(String.fromCharCode(10));
    const m6 = (name: string): string => {
      const m = join(temp, name);
      put(m, "specs/IDEA-001-demo-Specs/ROADMAP.md", `# Roadmap
## Execution Plan
| Order | Spec | Delivery | Depends on | Lane |
|--|--|--|--|--|
${rows}
`);
      for (let n = 1; n <= 6; n++) put(m, `specs/IDEA-001-demo-Specs/SPEC-00${n}-s/SPEC-00${n}-s.md`, "# stub");
      return m;
    };
    const t: Record<string, [number, number]> = {};
    const m = m6("sched-six");
    expect(
      await scheduleSpecs(m, {
        ...opts({ maxParallel: 4 }), until: 11, independent: true, fanout: "WRITE",
        runDriver: async (_d, args) => {
          const spec = args[args.indexOf("--input") + 1]!;
          const a = Date.now();
          await Bun.sleep(900);
          t[spec] = [a, Date.now()];
          return 0;
        },
      }),
    ).toBe(0);
    const all = Object.values(t);
    expect(all.length).toBe(6);
    expect(Math.max(...all.map((x) => x[0]))).toBeLessThan(Math.min(...all.map((x) => x[1]))); // the sixth started before the first ended
    // The build phase is bounded by --max-parallel: six independent specs (no Depends on), at most 2 at a time.
    const m2 = join(temp, "sched-six-build");
    put(m2, "specs/IDEA-001-demo-Specs/ROADMAP.md", `# Roadmap
## Execution Plan
| Order | Spec | Delivery | Depends on | Lane |
|--|--|--|--|--|
${rows}
`);
    for (let n = 1; n <= 6; n++) put(m2, `specs/IDEA-001-demo-Specs/SPEC-00${n}-s/SPEC-00${n}-s.md`, "# stub");
    let now = 0;
    let peak = 0;
    await scheduleSpecs(m2, {
      ...opts({ maxParallel: 2 }),
      runDriver: async () => {
        peak = Math.max(peak, ++now);
        await Bun.sleep(200);
        now--;
        return 0;
      },
    });
    expect(peak).toBe(2);
  });

  test("the build lanes after the fan-out start at the state after it and still wait for their dependencies", async () => {
    const m = main("sched-build");
    const order: string[] = [];
    const argv: string[][] = [];
    await scheduleSpecs(m, {
      ...opts({}), from: 14,
      runDriver: async (dir, args) => {
        order.push(args[args.indexOf("--input") + 1]!);
        argv.push(args);
        put(dir, `specs/IDEA-001-demo-Specs/x-${order.length}.txt`, "x");
        return 0;
      },
    });
    expect(order).toEqual(["SPEC-001", "SPEC-002", "SPEC-003"]); // a chain runs one after another
    for (const a of argv) {
      expect(a.slice(a.indexOf("--from"), a.indexOf("--from") + 2)).toEqual(["--from", "14"]);
      expect(a.slice(a.indexOf("--until"), a.indexOf("--until") + 2)).toEqual(["--until", "17"]);
    }
  });

  test("a lane whose gate was answered has already run through its state: it is merged without another driver run, and the scheduler ends", async () => {
    const m = main("sched-past");
    put(m, ".kcc-lanes/SPEC-002/coordination/run/run.json", JSON.stringify({ state: "14", status: "stopped", reason: "until 11" }));
    put(m, ".kcc-lanes/SPEC-002/.kcc-lane/base.json", JSON.stringify({ spec: "SPEC-002", base: {} }));
    put(m, ".kcc-lanes/SPEC-002/specs/IDEA-001-demo-Specs/SPEC-002-b/plan.md", "plan");
    const ran: string[] = [];
    const code = await scheduleSpecs(m, { ...opts({}), until: 11, independent: true, fanout: "PLAN", only: ["SPEC-002"], runDriver: async (_d, a) => { ran.push(a.join(" ")); return 0; } });
    expect(code).toBe(0);
    expect(ran).toEqual([]);
    expect(existsSync(join(m, "specs/IDEA-001-demo-Specs/SPEC-002-b/plan.md"))).toBe(true);
    expect(existsSync(laneDir(m, "SPEC-002"))).toBe(false);
  });

  test("one failing spec stops the phase with exit 4 and the others are merged; the failed lane is kept", async () => {
    const m = main("sched-fail");
    const code = await scheduleSpecs(m, {
      ...opts({}), until: 11, independent: true, fanout: "PLAN",
      runDriver: async (dir, args) => {
        const spec = args[args.indexOf("--input") + 1]!;
        if (spec === "SPEC-002") return 4;
        put(dir, `specs/IDEA-001-demo-Specs/${spec}.plan`, "ok");
        return 0;
      },
    });
    expect(code).toBe(4);
    expect(existsSync(join(m, "specs/IDEA-001-demo-Specs/SPEC-001.plan"))).toBe(true);
    expect(existsSync(join(m, "specs/IDEA-001-demo-Specs/SPEC-003.plan"))).toBe(true);
    expect(existsSync(laneDir(m, "SPEC-002"))).toBe(true);
  });
});

// ---------------------------------------------------------------------------- real drivers against the stub harness

function workspace(name: string, specs: number): string {
  const root = join(temp, name);
  applyPayload(root);
  const git = (...a: string[]) => spawnSync("git", a, { cwd: root, encoding: "utf8" });
  git("init", "-q"); git("config", "user.email", "t@example.com"); git("config", "user.name", "T"); git("config", "core.autocrlf", "false");
  writeFileSync(join(root, "README.md"), "demo\n");
  git("add", "-A"); git("commit", "-q", "-m", "base");
  mkdirSync(join(root, ".kcc-stub"), { recursive: true });
  copyFileSync(STUB, join(root, ".kcc-stub", "stub.sh"));
  writeFileSync(join(root, ".kcc-stub", "mode"), "happy");
  writeFileSync(join(root, ".kcc-stub", "specs"), String(specs));
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
const drv = isWindows ? ps : sh;
const FT = ["--input", "a tiny app", "--silent", "--assume", "--fasttrack"];
const SPECDIR = "specs/IDEA-001-demo-Specs";
const specFolder = (root: string, id: string): string => readdirSync(join(root, SPECDIR)).find((d) => d.startsWith(id + "-"))!;
const times = (root: string, spec: string, state: string): { start: number; end: number }[] => {
  const f = join(root, ".kcc-stub", `times-${spec}.log`);
  if (!existsSync(f)) return [];
  const rows = readFileSync(f, "utf8").trim().split(/\r?\n/).map((l) => l.split(" ")).filter((c) => c[2] === state);
  const out: { start: number; end: number }[] = [];
  for (const c of rows) {
    if (c[1] === "start") out.push({ start: Number(c[0]), end: NaN });
    else out[out.length - 1]!.end = Number(c[0]);
  }
  return out;
};
const dispatches = (root: string, state: string, spec: string): number => times(root, spec, state).length;
const sharedStates = (root: string): void => {
  const r = drv(root, [...FT, "--until", "9"]);
  expect(r.status).toBe(0);
};

describe("the bare driver does WRITE and PLAN spec by spec", () => {
  const root = workspace("bare", 3);
  test("SPECS writes the split only: a roadmap and a stub note per spec, no Backlog, no plan; its prompt says so", () => {
    sharedStates(root);
    const log = read(root, "coordination/run/logs/state-9-run-1.log");
    expect(log).toContain("--split-only");
    expect(log).toContain("no plan.md");
    expect(log).not.toMatch(/one \/spec-plan SPEC/);
    for (const id of ["SPEC-001", "SPEC-002", "SPEC-003"]) {
      const dir = join(root, SPECDIR, specFolder(root, id));
      expect(existsSync(join(dir, `${specFolder(root, id)}.md`))).toBe(true);
      expect(existsSync(join(dir, "plan.md"))).toBe(false);
      expect(existsSync(join(dir, "Backlog"))).toBe(false);
    }
    expect(read(root, ".kcc-stub/calls.log")).not.toMatch(/state=1[01]/); // neither WRITE nor PLAN has run yet
  });
  test("--only 10 writes the specs one after another, --only 11 plans them one after another, each with its own log", () => {
    writeFileSync(join(root, ".kcc-stub", "sleep"), "1");
    expect(drv(root, ["--only", "10"]).status).toBe(0);
    expect(drv(root, ["--only", "11"]).status).toBe(0);
    for (const state of ["10", "11"]) {
      const t = ["SPEC-001", "SPEC-002", "SPEC-003"].map((s) => times(root, s, state)[0]!);
      expect(t[0]!.end).toBeLessThanOrEqual(t[1]!.start);
      expect(t[1]!.end).toBeLessThanOrEqual(t[2]!.start);
    }
    for (const id of ["SPEC-001", "SPEC-002", "SPEC-003"]) {
      expect(existsSync(join(root, SPECDIR, specFolder(root, id), "plan.md"))).toBe(true);
      expect(existsSync(join(root, "coordination/run/logs", `state-10-${id}-1.log`))).toBe(true);
      expect(existsSync(join(root, "coordination/run/logs", `state-11-${id}-1.log`))).toBe(true);
    }
  });
  test("every dispatch records agent-run-started and agent-run-ended with its spec and agent", () => {
    const ev = read(root, "coordination/backchannel.jsonl").trim().split(/\r?\n/).map((l) => JSON.parse(l));
    for (const kind of ["agent-run-started", "agent-run-ended"]) {
      const planners = ev.filter((e) => e.kind === kind && e.payload.state === 11);
      expect(planners.map((e) => e.spec).sort()).toEqual(["SPEC-001", "SPEC-002", "SPEC-003"]);
      expect(planners.every((e) => e.payload.agent === "planner" && e.ts)).toBe(true);
    }
    const writers = ev.filter((e) => e.kind === "agent-run-ended" && e.payload.state === 10);
    expect(writers.every((e) => e.payload.agent === "spec-writer" && e.payload.exit === 0)).toBe(true);
  });
});

describe("a missing plan fails only that spec's PLAN step", () => {
  const root = workspace("noplan", 3);
  test("SPEC-002 is retried (attempt count per spec) and then, silent, is parked as needs-attention (exit 7, no pause); SPEC-001 is dispatched once, SPEC-003 never", () => {
    sharedStates(root);
    expect(drv(root, ["--only", "10"]).status).toBe(0);
    writeFileSync(join(root, ".kcc-stub", "noplan"), "SPEC-002\n");
    const r = drv(root, ["--only", "11", "--max-attempts", "2"]);
    expect(r.status).toBe(7);
    expect(r.stdout).toContain("PLAN-001");
    expect(r.stdout).toContain("state 11 PLAN SPEC-002");
    expect(dispatches(root, "11", "SPEC-001")).toBe(1);
    expect(dispatches(root, "11", "SPEC-002")).toBe(2);
    expect(dispatches(root, "11", "SPEC-003")).toBe(0);
    expect(JSON.parse(read(root, "coordination/run/run.json")).attempts ?? "").not.toContain("11:SPEC-002"); // parked: the unit starts fresh on a resume
    expect(read(root, "coordination/NeedsAttention.md")).toContain("## [open] SPEC-002 | loop | state 11 PLAN");
    expect(existsSync(join(root, SPECDIR, specFolder(root, "SPEC-001"), "plan.md"))).toBe(true);
    expect(existsSync(join(root, SPECDIR, specFolder(root, "SPEC-002"), "plan.md"))).toBe(false);
  });
});

describe("kcc run: WRITE then PLAN for all specs at the same time (real drivers in lanes)", () => {
  const root = workspace("lanes", 3);
  const logs: string[] = [];
  test("three writers overlap, then three planners overlap; every spec ends with a note and a plan; the lanes are merged and removed", async () => {
    sharedStates(root);
    writeFileSync(join(root, ".kcc-stub", "sleep"), "8");
    const r = await fanoutSpecs(root, { passthrough: ["--fasttrack", "--silent", "--assume"], maxParallel: 3, syncSeconds: 5, log: (l) => logs.push(l) });
    expect(r).toEqual({ code: 0, after: 14 });
    for (const state of ["10", "11"]) {
      const t = ["SPEC-001", "SPEC-002", "SPEC-003"].map((s) => times(root, s, state)[0]!);
      expect(t.every((x) => x && Number.isFinite(x.end))).toBe(true);
      expect(Math.max(...t.map((x) => x.start))).toBeLessThan(Math.min(...t.map((x) => x.end))); // all three at once
    }
    const lastWrite = Math.max(...["SPEC-001", "SPEC-002", "SPEC-003"].map((s) => times(root, s, "10")[0]!.end));
    const firstPlan = Math.min(...["SPEC-001", "SPEC-002", "SPEC-003"].map((s) => times(root, s, "11")[0]!.start));
    expect(lastWrite).toBeLessThanOrEqual(firstPlan); // a plan starts only when every spec is written
    for (const id of ["SPEC-001", "SPEC-002", "SPEC-003"]) {
      const dir = join(root, SPECDIR, specFolder(root, id));
      expect(existsSync(join(dir, "plan.md"))).toBe(true);
      expect(existsSync(join(dir, "Backlog", "Story-001-create-item.md"))).toBe(true);
      expect(existsSync(laneDir(root, id))).toBe(false);
    }
    const ev = read(root, "coordination/backchannel.jsonl").trim().split(/\r?\n/).map((l) => JSON.parse(l));
    const ended = ev.filter((e) => e.kind === "agent-run-ended" && e.payload.state === 11);
    expect(ended.map((e) => e.spec).sort()).toEqual(["SPEC-001", "SPEC-002", "SPEC-003"]);
    expect(ev.filter((e) => e.kind === "agent-run-started" && e.payload.agent === "planner").length).toBe(3);
    expect(logs.join("\n")).toContain("state 10 WRITE for 3 spec(s) at the same time");
  });
  test("with every plan present a second pass runs nothing", async () => {
    const before = readFileSync(join(root, ".kcc-stub", "times-SPEC-001.log"), "utf8");
    expect(await fanoutSpecs(root, { passthrough: ["--fasttrack"], maxParallel: 3, log: () => {} })).toEqual({ code: 0, after: 14 });
    expect(readFileSync(join(root, ".kcc-stub", "times-SPEC-001.log"), "utf8")).toBe(before);
  });
});

describe("kcc run: a planner that writes no plan stops only its own lane", () => {
  const root = workspace("lanes-fail", 3);
  test("the other plans are merged, SPEC-002 keeps its lane and pauses at the loop gate (retrying alone); answering it lets the next pass finish", async () => {
    sharedStates(root);
    writeFileSync(join(root, ".kcc-stub", "noplan"), "SPEC-002\n");
    // Not silent: a run without --silent --assume keeps its blocking gates (the silent variant is tested below).
    const flags = ["--fasttrack", "--max-attempts", "2"];
    const logs: string[] = [];
    const r = await fanoutSpecs(root, { passthrough: flags, maxParallel: 3, log: (l) => logs.push(l) });
    expect(r.code).toBe(4);
    expect(existsSync(join(root, SPECDIR, specFolder(root, "SPEC-001"), "plan.md"))).toBe(true);
    expect(existsSync(join(root, SPECDIR, specFolder(root, "SPEC-003"), "plan.md"))).toBe(true);
    expect(dispatches(root, "11", "SPEC-001")).toBe(1);
    expect(existsSync(laneDir(root, "SPEC-002"))).toBe(true);
    expect(dispatches(laneDir(root, "SPEC-002"), "11", "SPEC-002")).toBe(2); // two attempts, counted for this spec alone
    // The owner fixes the cause and answers the lane's gate (kcc run --lane SPEC-002 --answer revise), then resumes.
    const lane = laneDir(root, "SPEC-002");
    rmSync(join(lane, ".kcc-stub", "noplan"), { force: true });
    expect(runTool(lane, "kcc-run", ["--answer", "revise", "--repo-root", lane], { capture: true }).status).toBe(0);
    logs.length = 0;
    expect(await fanoutSpecs(root, { passthrough: flags, maxParallel: 3, log: (l) => logs.push(l) })).toEqual({ code: 0, after: 14 });
    expect(logs.join("\n")).toContain("state 11 PLAN for 1 spec(s)");
    expect(existsSync(join(root, SPECDIR, specFolder(root, "SPEC-002"), "plan.md"))).toBe(true);
    expect(existsSync(laneDir(root, "SPEC-002"))).toBe(false);
    expect(dispatches(root, "11", "SPEC-001")).toBe(1); // never run again
  });
});

describe("kcc run --silent --assume: a planner that writes no plan parks only its own lane (exit 7), the others go on", () => {
  const root = workspace("lanes-silent", 3);
  test("no gate pauses; SPEC-002 is parked as needs-attention (kept in lanes.json and NeedsAttention.md), SPEC-001 and SPEC-003 are planned and merged", async () => {
    sharedStates(root);
    writeFileSync(join(root, ".kcc-stub", "noplan"), "SPEC-002\n");
    const logs: string[] = [];
    const r = await fanoutSpecs(root, { passthrough: ["--fasttrack", "--silent", "--assume", "--max-attempts", "2"], maxParallel: 3, log: (l) => logs.push(l) });
    expect(r.code).toBe(7);
    expect(r.attention).toEqual(["SPEC-002"]);
    expect(existsSync(join(root, SPECDIR, specFolder(root, "SPEC-001"), "plan.md"))).toBe(true);
    expect(existsSync(join(root, SPECDIR, specFolder(root, "SPEC-003"), "plan.md"))).toBe(true);
    expect(existsSync(join(root, SPECDIR, specFolder(root, "SPEC-002"), "plan.md"))).toBe(false);
    const lane = laneDir(root, "SPEC-002");
    expect(existsSync(lane)).toBe(true);
    const lj = JSON.parse(readFileSync(join(lane, "coordination", "run", "run.json"), "utf8"));
    expect(lj.gate_id).toBe(""); // nothing waits for a human
    expect(lj.status).toBe("stopped");
    expect(lj.reason).toContain("needs attention");
    expect(dispatches(lane, "11", "SPEC-002")).toBe(2);
    expect(JSON.parse(read(root, "coordination/lanes.json"))["SPEC-002"]).toMatchObject({ status: "needs-attention", exit: 7 });
    const na = read(root, "coordination/NeedsAttention.md");
    expect(na).toContain("## [open] SPEC-002 | loop | state 11 PLAN");
    expect(na).toContain("PLAN-001");
    expect(na).toMatch(/- todo: .*kcc run --lane SPEC-002 --from 11/);
    expect(logs.join("\n")).toContain("SPEC-002 needs attention");
  });
});

describe("a lane that stops is synced into the workspace at once", () => {
  const ROADMAP = `# Roadmap
## Execution Plan
| Order | Spec | Delivery | Depends on | Lane |
|--|--|--|--|--|
| 1 | SPEC-001 | a | None | A |
| 2 | SPEC-002 | b | None | A |
| 3 | SPEC-003 | c | SPEC-001 | A |
`;
  const mk = (name: string): string => {
    const m = join(temp, name);
    put(m, "specs/IDEA-001-demo-Specs/ROADMAP.md", ROADMAP);
    for (const s of ["SPEC-001-a", "SPEC-002-b", "SPEC-003-c"]) put(m, `specs/IDEA-001-demo-Specs/${s}/${s}.md`, "# stub");
    return m;
  };
  const SECTION = "## [open] SPEC-001 | loop | state 16 TEST | 2026-10-17T00:00:00Z\n\n- when: 2026-10-17T00:00:00Z\n- spec: SPEC-001\n- status: open\n\n";

  test("parked under --silent --assume: its src/ is in the workspace, its NeedsAttention section was appended, the others merged, the run exits 7", async () => {
    const m = mk("sched-parked");
    const code = await scheduleSpecs(m, {
      passthrough: ["--fasttrack", "--silent", "--assume"], maxParallel: 3, syncSeconds: 0.2, log: () => {},
      runDriver: async (dir, args) => {
        const spec = args[args.indexOf("--input") + 1]!;
        put(dir, `src/IDEA-001-demo/${spec}.ts`, `export const ${spec.replace("-", "_")} = 1;`);
        put(dir, `TestResults/IDEA-001-demo/${spec}/note.md`, "evidence");
        if (spec !== "SPEC-001") return 0;
        put(dir, "coordination/NeedsAttention.md", `# Needs attention\n\nheader\n\n${SECTION}`);
        put(dir, "coordination/run/run.json", JSON.stringify({ state: "16", status: "stopped", reason: "needs attention: SPEC-001 loop at state 16 TEST" }));
        return 7;
      },
    });
    expect(code).toBe(7);
    expect(existsSync(join(m, "src/IDEA-001-demo/SPEC-001.ts"))).toBe(true); // the parked lane's code is in the workspace
    expect(existsSync(join(m, "src/IDEA-001-demo/SPEC-002.ts"))).toBe(true); // the merged lane's too
    expect(existsSync(join(m, "src/IDEA-001-demo/SPEC-003.ts"))).toBe(false); // it waits for SPEC-001
    expect(existsSync(join(m, "TestResults/IDEA-001-demo/SPEC-001/note.md"))).toBe(true);
    expect(read(m, "coordination/NeedsAttention.md")).toContain(SECTION);
    const lj = JSON.parse(read(m, "coordination/lanes.json"));
    expect(lj["SPEC-001"]).toMatchObject({ status: "needs-attention", exit: 7 });
    expect(lj["SPEC-001"].reason).toContain("needs attention");
    expect(lj["SPEC-002"].status).toBe("merged");
    expect(lj["SPEC-003"]).toMatchObject({ status: "needs-attention" });
    expect(lj["SPEC-003"].reason).toContain("waits for SPEC-001");
    expect(existsSync(laneDir(m, "SPEC-001"))).toBe(true); // kept for the human
    expect(existsSync(laneDir(m, "SPEC-002"))).toBe(false);
  });

  test("a lane that pauses at a gate (exit 4, not silent) also leaves its src/ in the workspace; a file both sides changed is kept as the workspace copy and reported", async () => {
    const m = mk("sched-gated");
    put(m, "src/shared.ts", "workspace v1");
    const code = await scheduleSpecs(m, {
      passthrough: ["--fasttrack"], maxParallel: 3, syncSeconds: 0.2, log: () => {},
      runDriver: async (dir, args) => {
        const spec = args[args.indexOf("--input") + 1]!;
        put(dir, `src/IDEA-001-demo/${spec}.ts`, "code");
        if (spec !== "SPEC-002") return 0;
        put(m, "src/shared.ts", "workspace v2"); // the workspace changes the file while the lane runs ...
        put(dir, "src/shared.ts", "lane v2"); // ... and so does the lane
        put(dir, "coordination/run/run.json", JSON.stringify({ state: "16", status: "paused", gate_id: "GATE-001", gate_name: "loop" }));
        return 4;
      },
    });
    expect(code).toBe(4);
    expect(existsSync(join(m, "src/IDEA-001-demo/SPEC-002.ts"))).toBe(true);
    expect(read(m, "src/shared.ts")).toBe("workspace v2");
    expect(JSON.parse(read(m, "coordination/lanes.json"))["SPEC-002"].reason).toContain("merge conflict: src/shared.ts");
  });

  test("under --silent --assume a conflict on a stopped lane is an open NeedsAttention item, never dropped", async () => {
    const m = mk("sched-conflict");
    put(m, "src/shared.ts", "workspace v1");
    await scheduleSpecs(m, {
      passthrough: ["--fasttrack", "--silent", "--assume"], maxParallel: 3, syncSeconds: 0.2, log: () => {},
      runDriver: async (dir, args) => {
        const spec = args[args.indexOf("--input") + 1]!;
        if (spec !== "SPEC-002") return 0;
        put(m, "src/shared.ts", "workspace v2");
        put(dir, "src/shared.ts", "lane v2");
        return 7;
      },
    });
    const na = read(m, "coordination/NeedsAttention.md");
    expect(na).toContain("## [open] SPEC-002 | merge-conflict");
    expect(na).toContain("src/shared.ts");
  });

  test("a lane's git ignores its own .kcc-lane/ marker folder: appended to the copied .gitignore only when it is missing", () => {
    const a = mk("lane-ignore-a");
    put(a, ".gitignore", "node_modules/\n");
    const la = createLane(a, "SPEC-001", false).dir;
    expect(read(la, ".gitignore")).toBe("node_modules/\n.kcc-lane/\n");
    expect(spawnSync("git", ["status", "--porcelain"], { cwd: la, encoding: "utf8" }).stdout).not.toContain(".kcc-lane");
    const b = mk("lane-ignore-b");
    put(b, ".gitignore", "dist/\n.kcc-lane/\n");
    expect(read(createLane(b, "SPEC-001", false).dir, ".gitignore")).toBe("dist/\n.kcc-lane/\n"); // not twice
    const c = mk("lane-ignore-c"); // no .gitignore at all
    expect(read(createLane(c, "SPEC-001", false).dir, ".gitignore")).toBe(".kcc-lane/\n");
    expect(existsSync(join(c, ".gitignore"))).toBe(false); // the workspace's own files are not touched
  });
});

describe("the split writes the per-idea index the planners read", () => {
  test("SPECS without IDEA-NNN-slug-Specs.md fails SPEC-006 (a silent run parks it, exit 7); with it the state passes", () => {
    const missing = workspace("noindex", 2);
    writeFileSync(join(missing, ".kcc-stub", "noindex"), "x");
    const r = drv(missing, [...FT, "--until", "9", "--max-attempts", "1"]);
    expect(r.status).toBe(7);
    expect(r.stdout).toContain("SPEC-006");
    expect(existsSync(join(missing, SPECDIR, "IDEA-001-demo-Specs.md"))).toBe(false);
    const ok = workspace("withindex", 2);
    expect(drv(ok, [...FT, "--until", "9"]).status).toBe(0);
    const idx = read(ok, `${SPECDIR}/IDEA-001-demo-Specs.md`);
    expect(idx).toContain("ideation");
  });
});
