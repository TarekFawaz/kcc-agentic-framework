import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { runTool } from "../src/platform";

// kcc-run --until <id> hands the per-spec states to `kcc lanes`: it stops after that state, resumable.
setDefaultTimeout(120000);
const root = mkdtempSync(join(tmpdir(), "kcc-until-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const git = (...a: string[]) => spawnSync("git", a, { cwd: root, encoding: "utf8" });
const run = (...a: string[]) => runTool(root, "kcc-run", ["--input", "a tiny tool", "--silent", "--assume", "--fasttrack", ...a], { capture: true });

describe("kcc-run --until", () => {
  test("setup", () => {
    applyPayload(root);
    git("init", "-q");
    git("config", "user.email", "t@example.com");
    git("config", "user.name", "T");
    writeFileSync(join(root, "README.md"), "x");
    git("add", "-A");
    git("commit", "-q", "-m", "base");
  });

  test("an unknown state id is a usage error", () => {
    expect(run("--until", "999").status).toBe(2);
    expect(run("--until", "abc").status).toBe(2);
  });

  test("it stops after the named state and the run stays resumable", () => {
    const r = run("--until", "0");
    expect(r.status).toBe(0);
    const f = join(root, "coordination", "run", "run.json");
    expect(existsSync(f)).toBe(true);
    const j = JSON.parse(readFileSync(f, "utf8"));
    expect(j.status).toBe("stopped");
    expect(j.reason).toBe("until 0");
    expect(Number(j.state)).toBeGreaterThan(0);
  });

  test("--until is kept in run.json, so a resume (for example by the limit watcher) stops there too", () => {
    const f = join(root, "coordination", "run", "run.json");
    const j = JSON.parse(readFileSync(f, "utf8"));
    expect(j.until).toBe(""); // cleared once reached, so a deliberate resume continues
    j.state = "0";
    j.status = "stopped";
    j.until = "0";
    writeFileSync(f, JSON.stringify(j));
    const r = runTool(root, "kcc-run", ["--resume"], { capture: true });
    expect(r.status).toBe(0);
    const k = JSON.parse(readFileSync(f, "utf8"));
    expect(k.reason).toBe("until 0");
    expect(k.status).toBe("stopped");
  });
});
