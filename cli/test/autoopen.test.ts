import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { payloadFiles } from "../src/payload";
import { runTool } from "../src/platform";

// The dashboard opens only with the human's permission: a flag, or settings dashboard.auto_open.
// KCC_OPEN_LOG makes build-dashboard record the path instead of launching a browser.
setDefaultTimeout(120000); // each case starts a real kcc-run
const root = mkdtempSync(join(tmpdir(), "kcc-open-"));
const log = join(root, "opened.log");
afterAll(() => rmSync(root, { recursive: true, force: true }));

const settingsPath = join(root, ".KCC", "settings.json");
const runPath = join(root, "coordination", "run", "run.json");

function setMode(mode: string): void {
  const s = JSON.parse(readFileSync(settingsPath, "utf8"));
  s.dashboard = { auto_open: mode };
  writeFileSync(settingsPath, JSON.stringify(s, null, 2) + "\n");
}

function start(extra: string[] = [], env: Record<string, string> = {}): { out: string; opened: number; run: any } {
  rmSync(runPath, { force: true });
  rmSync(log, { force: true });
  const r = runTool(root, "kcc-run", ["--input", "a tiny idea", "--only", "0", "--repo-root", root, ...extra], {
    capture: true,
    env: { KCC_OPEN_LOG: log, KCC_DASHBOARD_ANSWER: "", ...env },
  });
  const opened = existsSync(log) ? readFileSync(log, "utf8").split(/\r?\n/).filter(Boolean).length : 0;
  const run = existsSync(runPath) ? JSON.parse(readFileSync(runPath, "utf8")) : {};
  return { out: r.stdout + r.stderr, opened, run };
}

describe("dashboard opens only with permission", () => {
  beforeAll(() => {
    applyPayload(root);
    const git = (...a: string[]) => execFileSync("git", a, { cwd: root, stdio: "ignore" });
    git("init", "-q");
    git("config", "user.email", "t@t");
    git("config", "user.name", "t");
    writeFileSync(join(root, "README.md"), "x");
    git("add", "-A");
    git("commit", "-qm", "init");
  });

  test("with no recorded permission nothing opens and a hint is printed", () => {
    setMode("ask");
    const r = start();
    expect(r.opened).toBe(0);
    expect(r.out).toContain("dashboard not opened");
  });

  test("--open-dashboard is permission for this run", () => {
    setMode("ask");
    const r = start(["--open-dashboard"]);
    expect(r.opened).toBe(1);
    expect(readFileSync(log, "utf8")).toContain("index.html");
    expect(String(r.run.dashboard_opened)).toBe("1");
  });

  test("--no-open-dashboard wins over a saved yes", () => {
    setMode("yes");
    const r = start(["--no-open-dashboard"]);
    expect(r.opened).toBe(0);
    expect(String(r.run.dashboard_opened)).toBe("declined");
  });

  test("auto_open yes opens, auto_open no does not", () => {
    setMode("yes");
    expect(start().opened).toBe(1);
    setMode("no");
    expect(start().opened).toBe(0);
  });

  test("answering 'always' opens it and saves the choice", () => {
    setMode("ask");
    const r = start([], { KCC_DASHBOARD_ANSWER: "always" });
    expect(r.opened).toBe(1);
    expect(JSON.parse(readFileSync(settingsPath, "utf8")).dashboard.auto_open).toBe("yes");
  });

  test("answering 'never' declines it and saves the choice", () => {
    setMode("ask");
    const r = start([], { KCC_DASHBOARD_ANSWER: "never" });
    expect(r.opened).toBe(0);
    expect(JSON.parse(readFileSync(settingsPath, "utf8")).dashboard.auto_open).toBe("no");
  });
});

describe("a silent run never prompts", () => {
  // A console prompt cannot be driven from a test, so pin the guard in both drivers: a measured round once hung
  // on this question although it was started with --silent.
  test("both drivers skip the dashboard question when --silent is set", () => {
    const text = (n: string): string => payloadFiles().get(`tools/${n}`)!.toString("utf8");
    expect(text("kcc-run.ps1")).toMatch(/\$console = .*-and -not \$Silent/);
    expect(text("kcc-run.sh")).toMatch(/-t 0 && -t 1 && \$JSON -eq 0 && \$SILENT -eq 0/);
  });
  test("a silent run answers a deferred quality check itself (never a pass) and never waits on a console for any gate", () => {
    const text = (n: string): string => payloadFiles().get(`tools/${n}`)!.toString("utf8");
    for (const f of ["kcc-run.ps1", "kcc-run.sh"]) {
      const t = text(f);
      expect(t).toContain("deferred quality check accepted by policy (not a pass)");
      expect(t).toMatch(/accept-deferred/);
    }
    expect(text("kcc-run.ps1")).toMatch(/if \(\$R\.silent -eq '1'\) \{[\s\S]*?return 'paused'/);
    expect(text("kcc-run.sh")).toMatch(/if \[\[ "\$R_silent" == "1" \]\]; then[\s\S]*?return 0/);
  });
});
