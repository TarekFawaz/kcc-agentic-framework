import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { dashboardFingerprint, rebuildDashboard, type DashStamp } from "../src/run/dashstale";

// The lane scheduler, a lane's supervisor and the live page all ask for a dashboard rebuild on a timer or on every page request.
// A rebuild is seconds (minutes under Git Bash), so it must not run when no file the builder reads has changed.
setDefaultTimeout(120000);
const root = mkdtempSync(join(tmpdir(), "kcc-dashstale-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

// A stand-in for build-dashboard that only counts how often it ran (the real one is covered by the dashboard tests).
function stubTools(): void {
  const tools = join(root, ".KCC", "tools");
  mkdirSync(tools, { recursive: true });
  writeFileSync(join(tools, "build-dashboard.ps1"), "param([string]$RepoRoot)\nAdd-Content -LiteralPath (Join-Path $RepoRoot 'build.count') -Value 'x'\nexit 0\n");
  writeFileSync(join(tools, "build-dashboard.sh"), '#!/usr/bin/env bash\necho x >> "$2/build.count"\n', { mode: 0o755 });
}
const builds = (): number => { try { return readFileSync(join(root, "build.count"), "utf8").split(/\r?\n/).filter(Boolean).length; } catch { return 0; } };

describe("dashboard rebuilds only when an input changed", () => {
  test("the fingerprint follows the files the builder reads and ignores the page it writes", () => {
    mkdirSync(join(root, "coordination"), { recursive: true });
    writeFileSync(join(root, "coordination", "backchannel.jsonl"), '{"id":"BC-00001"}\n');
    const a = dashboardFingerprint(root);
    expect(dashboardFingerprint(root)).toBe(a); // nothing changed
    mkdirSync(join(root, "dashboard"), { recursive: true });
    writeFileSync(join(root, "dashboard", "index.html"), "<html></html>");
    mkdirSync(join(root, "node_modules", "x"), { recursive: true });
    writeFileSync(join(root, "node_modules", "x", "i.js"), "1");
    expect(dashboardFingerprint(root)).toBe(a); // the page itself and node_modules are not inputs
    appendFileSync(join(root, "coordination", "backchannel.jsonl"), '{"id":"BC-00002"}\n');
    expect(dashboardFingerprint(root)).not.toBe(a); // a new event is
    mkdirSync(join(root, "specs", "IDEA-001-x-Specs", "SPEC-001-y"), { recursive: true });
    const b = dashboardFingerprint(root);
    writeFileSync(join(root, "specs", "IDEA-001-x-Specs", "SPEC-001-y", "plan.md"), "# plan\n");
    expect(dashboardFingerprint(root)).not.toBe(b); // so is a file under specs/
  });

  test("a second ask with nothing new does not run the builder; a change, a force and an old page do", async () => {
    stubTools();
    const stamp: DashStamp = { sig: "", at: 0 };
    expect(await rebuildDashboard(root, stamp)).toBe(true);
    expect(builds()).toBe(1);
    expect(await rebuildDashboard(root, stamp)).toBe(false); // unchanged, and the page is seconds old
    expect(builds()).toBe(1);
    appendFileSync(join(root, "coordination", "backchannel.jsonl"), '{"id":"BC-00003"}\n');
    expect(await rebuildDashboard(root, stamp)).toBe(true);
    expect(builds()).toBe(2);
    expect(await rebuildDashboard(root, stamp, { force: true })).toBe(true); // the final sync of a lane
    expect(builds()).toBe(3);
    stamp.at = Date.now() - 120_000;
    expect(await rebuildDashboard(root, stamp)).toBe(true); // nothing changed, but the page is old: rebuilt so the time shown cannot go stale
    expect(builds()).toBe(4);
  });
});
