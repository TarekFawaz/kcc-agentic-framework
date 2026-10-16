import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { runTool } from "../src/platform";

// kcc-run assumes no harness: the flags come from kernel/harnesses.json and the models from kernel/models.json.
// Fast track on Codex or OpenCode (or Ollama models behind OpenCode) builds the same commands with that harness's own flags.
// The harness CLIs are not installed here, so this proves the commands the driver would run, not the runs themselves.
setDefaultTimeout(180000);
const root = mkdtempSync(join(tmpdir(), "kcc-harness-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const settingsPath = join(root, ".KCC", "settings.json");
const setSettings = (fn: (s: any) => void): void => {
  const s = JSON.parse(readFileSync(settingsPath, "utf8"));
  fn(s);
  writeFileSync(settingsPath, JSON.stringify(s, null, 2));
};
const plan = (): string[] =>
  runTool(root, "kcc-run", ["--input", "x", "--dry-run", "--silent", "--assume", "--fasttrack", "--repo-root", root], { capture: true })
    .stdout.split(/\r?\n/)
    .filter((l) => l.includes("harness:"));
const agentFiles = (dir: string): void => {
  mkdirSync(join(root, dir), { recursive: true });
  for (const a of ["idea-interrogator", "architect", "spec-writer", "implementer", "verifier"]) writeFileSync(join(root, dir, `${a}.md`), `---\nname: ${a}\n---\nx\n`);
};

describe("fast track on any harness", () => {
  test("claude: unchanged, agent and model and effort flags", () => {
    applyPayload(root);
    agentFiles(".claude/agents");
    setSettings((s) => { s.run.harness = "claude"; });
    const lines = plan();
    expect(lines.some((l) => l.includes("claude -p --agent implementer"))).toBe(true);
    expect(lines.find((l) => !l.includes("--agent"))).toContain("--model claude-haiku-5-5 --effort low");
  });

  test("codex: -m and -c model_reasoning_effort, the fast tier of codex, no agent flag so worker states share an orchestrator session", () => {
    agentFiles(".codex/agents");
    setSettings((s) => { s.run.harness = "codex"; });
    const lines = plan();
    expect(lines.length).toBeGreaterThanOrEqual(9);
    for (const l of lines) {
      expect(l).toContain("codex exec -m gpt-6-luna -c model_reasoning_effort=low ");
      expect(l).not.toContain("--agent");
      expect(l).not.toContain("claude");
    }
  });

  test("opencode: -m provider/model and an agent flag for a direct worker, no effort flag", () => {
    agentFiles(".opencode/agents");
    setSettings((s) => { s.run.harness = "opencode"; });
    const lines = plan();
    const direct = lines.find((l) => l.includes("--agent implementer"))!;
    expect(direct).toContain("opencode run --agent implementer "); // its model comes from the agent file the sync wrote
    for (const l of lines) {
      expect(l).toContain("opencode run ");
      expect(l).not.toContain("--effort");
      expect(l).not.toContain("model_reasoning_effort");
    }
  });

  test("ollama models behind opencode: run.registry picks the ollama column and its provider prefix", () => {
    setSettings((s) => { s.run.harness = "opencode"; s.run.registry = "ollama"; });
    const lines = plan();
    expect(lines.find((l) => !l.includes("--agent"))).toContain("opencode run -m ollama/qwen2.5:14b ");
    setSettings((s) => { delete s.run.registry; });
  });

  test("a project overrides how its harness takes a flag, and a Claude id is never sent to another harness", () => {
    setSettings((s) => { s.run.harness = "codex"; s.run.orchestrator_model = "claude-haiku-5-5"; s.harness_invoke = { codex: { effort: "" } }; });
    const lines = plan();
    for (const l of lines) {
      expect(l).toContain("codex exec -m gpt-6-luna ");
      expect(l).not.toContain("model_reasoning_effort");
      expect(l).not.toContain("claude-haiku");
    }
  });

  test("skills and agents are looked up in the harness's own folders, and neither driver names Claude's", () => {
    const h = JSON.parse(readFileSync(join(root, ".KCC", "kernel", "harnesses.json"), "utf8")).harnesses;
    expect(h.codex.skill_path).toBe(".codex/skills/{skill}/SKILL.md");
    expect(h.opencode.agent_dir).toBe(".opencode/agents");
    expect(h.generic.skill_path).toBe(".agents/skills/{skill}/SKILL.md");
    for (const f of ["kcc-run.ps1", "kcc-run.sh"]) {
      const src = readFileSync(join(root, ".KCC", "tools", f), "utf8");
      expect(src).toContain("skill_path");
      expect(src).toContain("agent_dir");
      expect(src).not.toMatch(/HarnessName -ne 'claude'|HARNESS" == "claude" \]\] \|\| return/);
    }
  });
});
