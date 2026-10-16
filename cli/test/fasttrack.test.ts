import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { payloadFiles } from "../src/payload";
import { runTool } from "../src/platform";

// --fasttrack drops ceremony (budgets, traces, long documents), never a production gate.
setDefaultTimeout(120000);
const root = mkdtempSync(join(tmpdir(), "kcc-ft-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const CEREMONY = ["ROI", "CONFIRM", "ARCH-GATE", "BUDGET-0", "BUDGET-P", "WINDOWS", "BUDGET-I"];

function states(): any[] {
  const text = payloadFiles().get("kernel/auto-states.json")!.toString("utf8");
  return JSON.parse(text).states;
}

describe("fasttrack keeps the production floor", () => {
  test("it can only skip ceremony states, never a gate or a quality state", () => {
    const skipped = states()
      .filter((s) => ([] as string[]).concat(s.skip_if_flag ?? []).includes("fasttrack"))
      .map((s) => s.name)
      .sort();
    expect(skipped).toEqual([...CEREMONY].sort());
    for (const keep of ["REPO", "PREFLIGHT", "IMPLEMENT", "TEST", "REVIEW", "CLOSE"]) {
      expect(skipped).not.toContain(keep);
    }
  });

  test("the TEST state runs the full quality gate and the review must be approved", () => {
    const test = states().find((s) => s.name === "TEST");
    expect(test.check.then.tool).toBe("quality-gate");
    expect(test.check.then.args).toEqual(["-Spec", "{SPEC}"]); // no -Scope: the full scope
    const review = JSON.stringify(states().find((s) => s.name === "REVIEW").check);
    expect(review).toContain("internal:review-verdict");
    expect(review).toContain("bugs");
  });

  test("quality-gate keeps its full default scope while a fasttrack run is active", () => {
    applyPayload(root);
    mkdirSync(join(root, "coordination", "run"), { recursive: true });
    writeFileSync(join(root, "coordination", "run", "run.json"), JSON.stringify({ status: "running", fasttrack: "1", depthlevel: "2" }));
    const r = runTool(root, "quality-gate", ["--repo-root", root, "--json"], { capture: true });
    const m = r.stdout.match(/"scope"\s*:\s*"([^"]*)"/);
    expect(m).not.toBeNull();
    expect(m![1]).toBe("all");
  });
});

describe("fasttrack keeps design quality and security", () => {
  const text = (rel: string): string => payloadFiles().get(rel)!.toString("utf8");

  test("a lean architecture review still runs, and specialists cover security and deployables", () => {
    const arch = states().find((s) => s.name === "ARCH").command_fasttrack as string;
    expect(arch).toContain("/architecture-review --fasttrack");
    expect(arch).toContain("standard for deployable");
    const spec = states().find((s) => s.name === "SPECIALISTS").command_fasttrack as string;
    expect(spec).toContain("security");
    expect(spec).toContain("infrastructure");
  });

  test("security-sensitive work never runs on the executor tier, and depth never trims security", () => {
    expect(text("kernel/templates/orchestrator.md")).toContain("security-sensitive");
    expect(text("capabilities/agents/planner.md")).toContain("security-sensitive");
    expect(text("capabilities/agents/implementer.md")).toContain("Security-sensitive work");
    expect(text("capabilities/agents/verifier.md")).toContain("security review of the diff");
    const floors = text("kernel/protocols/depth-levels.md").split("## Floors")[1]!.split("## Rules")[0]!;
    expect(floors).toContain("Security:");
    expect(floors).toContain("SAST");
  });
});

describe("fasttrack stays orchestrated, and the butler works in every run", () => {
  const settingsPath = join(root, ".KCC", "settings.json");
  const setSettings = (fn: (s: any) => void): void => {
    const s = JSON.parse(readFileSync(settingsPath, "utf8"));
    fn(s);
    writeFileSync(settingsPath, JSON.stringify(s, null, 2));
  };
  const plan = (extra: string[]): string[] =>
    runTool(root, "kcc-run", ["--input", "x", "--dry-run", "--silent", "--assume", "--repo-root", root, ...extra], { capture: true })
      .stdout.split(/\r?\n/)
      .filter((l) => l.includes("harness:"));
  const prep = (): void => {
    applyPayload(root);
    rmSync(join(root, "coordination", "run", "run.json"), { force: true }); // an earlier test left a run in progress
    mkdirSync(join(root, ".claude", "agents"), { recursive: true });
    for (const a of ["idea-interrogator", "technical-interrogator", "architect", "spec-writer", "planner", "implementer", "verifier"]) {
      writeFileSync(join(root, ".claude", "agents", `${a}.md`), `---\nname: ${a}\n---\nx\n`);
    }
  };

  test("under --fasttrack a state with one agent runs that agent directly; multi-agent states get a cheap orchestrator", () => {
    prep();
    const fast = plan(["--fasttrack"]);
    expect(fast.length).toBeGreaterThanOrEqual(9);
    const direct = fast.filter((l) => l.includes("--agent"));
    expect(direct.length).toBe(7); // IDEA ARCH SPECS IMPLEMENT FIX TEST REVIEW: every state with one agent runs it directly
    for (const l of fast.filter((l) => !l.includes("--agent"))) expect(l).toContain("--model claude-haiku-5-5 --effort low");
    expect(plan([]).join("\n")).not.toContain("--model claude-haiku"); // a normal run is unchanged
  });

  test("the orchestrator model is a setting, and direct worker runs can be switched off", () => {
    prep();
    setSettings((s) => { s.run.orchestrator_model = "claude-sonnet-5-5"; s.run.orchestrator_effort = "medium"; s.run.fasttrack_direct = false; });
    const wrapped = plan(["--fasttrack"]);
    expect(wrapped.join("\n")).not.toContain("--agent");
    expect(wrapped[0]).toContain("--model claude-sonnet-5-5 --effort medium");
    setSettings((s) => { s.run.orchestrator_model = "claude-haiku-5-5"; s.run.orchestrator_effort = "low"; s.run.fasttrack_direct = true; });
  });

  test("a settings.json that still says haiku/sonnet/opus is mapped to the pinned 5.5 IDs", () => {
    prep();
    for (const [alias, id] of [["haiku", "claude-haiku-5-5"], ["sonnet", "claude-sonnet-5-5"], ["opus", "claude-opus-5-5"]]) {
      setSettings((s) => { s.run.orchestrator_model = alias; });
      const first = plan(["--fasttrack"]).find((l) => !l.includes("--agent"))!; // the first orchestrated state (BRIEFS)
      expect(first).toContain(`--model ${id} `);
      expect(first).not.toMatch(new RegExp(`--model ${alias}\\b`));
    }
    setSettings((s) => { s.run.orchestrator_model = "claude-haiku-5-5"; });
  });

  test("the adapters pin full model IDs for Claude and current OpenAI models for Codex", () => {
    const sync = payloadFiles().get("tools/sync-adapters.ps1")!.toString("utf8");
    expect(sync).toContain("'fast-implementation' = 'claude-haiku-5-5'");
    expect(sync).not.toMatch(/\$ModelClassToClaude = @\{[^}]*'(opus|sonnet|haiku)'/);
    expect(sync).toContain("'fast-implementation' = 'gpt-6-luna'");
    const shSync = payloadFiles().get("tools/sync-adapters.sh")!.toString("utf8");
    expect(shSync).toContain('claude:fast-implementation|claude:local-fast) echo "claude-haiku-5-5"');
    expect(shSync).toContain('codex:fast-implementation|codex:local-fast) echo "gpt-6-luna"');
  });

  test("fast track has no butler before CLOSE (memory only, when run.butler is on); a full run wraps every unit", () => {
    const ft = JSON.parse(payloadFiles().get("kernel/auto-states-fasttrack.json")!.toString("utf8")).states;
    expect(ft.find((s: any) => s.name === "IDEA").command).not.toContain("butler");
    expect(ft.find((s: any) => s.name === "CLOSE").command).toContain("/butler-remember --fasttrack");
    for (const f of ["butler-brief", "butler-remember"]) {
      expect(payloadFiles().get(`capabilities/skills/${f}.md`)!.toString("utf8")).toContain("`--fasttrack`: memory only");
    }
    expect(payloadFiles().get("capabilities/agents/butler.md")!.toString("utf8")).toContain("Fasttrack mode (memory only)");
  });

  test("a full run's dispatch tells the orchestrator to brief and remember with the butler", () => {
    prep();
    setSettings((s) => { s.continuity.start.claude = 'echo fake -p --permission-mode {permission_mode} "{resume_prompt}"'; });
    const dispatchLine = (extra: string[]): string => {
      rmSync(join(root, "coordination", "run", "run.json"), { force: true });
      rmSync(join(root, "coordination", "run", "logs"), { recursive: true, force: true });
      runTool(root, "kcc-run", ["--input", "x", "--silent", "--assume", "--only", "1", "--max-attempts", "1", "--repo-root", root, ...extra], { capture: true });
      return readFileSync(join(root, "coordination", "run", "logs", "state-1-run-1.log"), "utf8").split(/\r?\n/)[1]!;
    };
    expect(dispatchLine([])).toContain("Wrap the work with the butler");
    const fast = dispatchLine(["--fasttrack"]);
    expect(fast).not.toContain("Wrap the work with the butler");
    expect(fast).toContain("--agent idea-interrogator"); // the fast-track IDEA runs the agent directly, no butler wrap
    setSettings((s) => { s.run.butler = "off"; });
    expect(dispatchLine([])).not.toContain("Wrap the work with the butler");
  });
});
