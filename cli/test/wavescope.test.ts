import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { applyPayload } from "../src/lock";
import { runTool } from "../src/platform";

// The scope baseline is a tag on HEAD and nothing commits between waves, so an earlier wave's
// work still shows as changed. A wave that wrote nothing must not pass.
setDefaultTimeout(120000);
const root = mkdtempSync(join(tmpdir(), "kcc-ws-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const git = (...a: string[]) => spawnSync("git", a, { cwd: root, encoding: "utf8" });
const put = (rel: string, text: string) => {
  mkdirSync(dirname(join(root, rel)), { recursive: true });
  writeFileSync(join(root, rel), text);
};

const SPEC = "specs/IDEA-001-demo-Specs/SPEC-001-core";
const item = (name: string, files: string[]) =>
  put(`${SPEC}/Backlog/${name}.md`, `# ${name}\n\n## Impacted Files\n${files.map((f) => `- \`${f}\``).join("\n")}\n`);

describe("check-wave-scope", () => {
  test("setup", () => {
    applyPayload(root);
    git("init", "-q");
    git("config", "user.email", "t@example.com");
    git("config", "user.name", "T");
    put(`${SPEC}/SPEC-001-core.md`, "# SPEC-001\n");
    put(`${SPEC}/plan.md`, "# Plan\n\n## Waves\n| Wave | Items | Files | File-disjoint | Notes |\n|--|--|--|--|--|\n| 1 | Enabler-001 | a | yes | |\n| 2 | Story-001 | b | yes | |\n");
    item("Enabler-001-scaffold", ["src/IDEA-001-demo/package.json"]);
    item("Story-001-feature", ["src/IDEA-001-demo/feature.ts"]);
    git("add", "-A");
    git("commit", "-q", "-m", "base");
  });

  const scope = (wave: number) => runTool(root, "check-wave-scope", ["--spec", "SPEC-001", "--wave", String(wave)], { capture: true });

  test("a wave that declares src files and wrote none of them fails (WAVE-004)", () => {
    const r = scope(1);
    expect(r.status).toBe(1);
    expect(r.stdout).toContain("WAVE-004");
  });

  test("a wave that wrote its declared files passes", () => {
    put("src/IDEA-001-demo/package.json", "{}");
    expect(scope(1).status).toBe(0);
  });

  test("an earlier wave's uncommitted files are not a violation in the next wave", () => {
    put("src/IDEA-001-demo/feature.ts", "export {};");
    const r = scope(2);
    expect(r.status).toBe(0);
    expect(r.stdout).not.toContain("WAVE-001");
  });

  test("a plan allowance row does not turn a wave that wrote nothing into a pass", () => {
    const planLines = [
      "# Plan", "", "## Waves",
      "| Wave | Items | Files | File-disjoint | Notes |", "|--|--|--|--|--|",
      "| 1 | Enabler-001 | a | yes | |", "| 2 | Story-001 | b | yes | |", "",
      "## Wave file allowances", "| Item | Paths |", "|--|--|",
      "| any | `src/IDEA-001-demo/package.json` |", "",
    ];
    put(`${SPEC}/plan.md`, planLines.join(String.fromCharCode(10)));
    rmSync(join(root, "src/IDEA-001-demo/feature.ts"), { force: true });
    rmSync(join(root, "src/IDEA-001-demo/stray.ts"), { force: true });
    const r = scope(2);
    expect(r.status).toBe(1);
    expect(r.stdout).toContain("WAVE-004");
  });

  test("a file no wave declared is still a violation", () => {
    put("src/IDEA-001-demo/stray.ts", "export {};");
    const r = scope(2);
    expect(r.status).toBe(1);
    expect(r.stdout).toContain("stray.ts");
  });

  test("every backticked path on an Impacted Files bullet counts, not only the first", () => {
    put(`${SPEC}/Backlog/Story-001-feature.md`, "# Story-001" + String.fromCharCode(10, 10) + "## Impacted Files" + String.fromCharCode(10) + "- `src/IDEA-001-demo/feature.ts`, `src/IDEA-001-demo/feature2.ts` and `/healthz` - two files" + String.fromCharCode(10));
    rmSync(join(root, "src/IDEA-001-demo/stray.ts"), { force: true });
    put("src/IDEA-001-demo/feature.ts", "export {};");
    put("src/IDEA-001-demo/feature2.ts", "export {};");
    const r = scope(2);
    expect(r.stdout).not.toContain("feature2.ts changed but");
  });

  test("a backlog item that puts code outside src/IDEA-{ID}-{slug}/ is rejected before implement (SPEC-008)", () => {
    item("Story-009-bad-path", ["src/api/server.ts"]);
    const r = runTool(root, "check-run-conformance", ["--scope", "specs", "--spec", "SPEC-001"], { capture: true });
    expect(r.stdout).toContain("SPEC-008");
    expect(r.stdout).toContain("src/api/server.ts");
    item("Story-009-bad-path", ["src/IDEA-001-demo/server.ts"]);
    expect(runTool(root, "check-run-conformance", ["--scope", "specs", "--spec", "SPEC-001"], { capture: true }).stdout).not.toContain("SPEC-008");
  });
});
