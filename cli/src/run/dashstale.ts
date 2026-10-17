import { createHash } from "node:crypto";
import { readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { runToolAsync } from "../platform";

/**
 * Rebuilding the dashboard is the most expensive thing the CLI asks a tool for (a PowerShell or bash process that reads every file of
 * every spec: seconds on a small workspace, minutes under Git Bash), and three loops ask for it on a timer or on every page request
 * (the lane scheduler, a lane's supervisor, the live page). Most of those asks find nothing changed. The dashboard is built from
 * files, so a fingerprint of the files it reads (path, size and last write) says whether a rebuild could produce a different page.
 */

const SKIP = new Set(["node_modules", ".git", "dashboard", ".agent-cache"]);

/** The folders and files the dashboard builders read, relative to the workspace, with how deep to look. */
const INPUTS: [string, number][] = [
  ["coordination", 10], ["specs", 10], ["ideation", 4], ["Traces", 4], ["architecture", 4], ["memory", 2], ["TestResults", 6],
  [".claude/agents", 1], [".KCC/settings.json", 0], [".KCC/kernel/auto-states.json", 0], [".KCC/kernel/auto-states-fasttrack.json", 0],
  [".KCC/kernel/templates/dashboard.html", 0], [".KCC/kernel/harnesses.json", 0], [".KCC/kernel/models.json", 0],
  // a lane is a copy of the workspace: its run state, events, spec folder, logs, and the files under its src (the page counts them)
  [".kcc-lanes", 6], [".worktrees", 6],
];

/** Fingerprint of everything the dashboard reads; "" parts for what does not exist. */
export function dashboardFingerprint(root: string): string {
  const h = createHash("sha1");
  const add = (p: string, depth: number): void => {
    let st;
    try { st = statSync(p); } catch { return; }
    h.update(p).update(":").update(String(st.mtimeMs)).update(":").update(String(st.size)).update("\n");
    if (st.isDirectory() && depth > 0) {
      let names: string[] = [];
      try { names = readdirSync(p); } catch { return; }
      for (const n of names.sort()) if (!SKIP.has(n)) add(join(p, n), depth - 1);
    }
  };
  for (const [rel, depth] of INPUTS) add(join(root, rel), depth);
  // the agent history comes from Claude Code transcripts, which live outside the workspace
  const config = process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
  add(join(config, "projects", root.replace(/[^A-Za-z0-9]/g, "-")), 3);
  return h.digest("hex");
}

export interface DashStamp {
  /** Fingerprint taken before the last successful build (so a change during the build is seen next time). */
  sig: string;
  /** When that build finished. */
  at: number;
}

/** A dashboard older than this is rebuilt even when no file changed, so the time shown and anything outside the fingerprint cannot go stale. */
export const DASH_MAX_UNCHANGED_MS = 60_000;

/**
 * Rebuilds dashboard/index.html unless no input changed since the last build recorded in `stamp` (and that build is recent).
 * Returns true when the builder ran and succeeded. `force` always builds.
 */
export async function rebuildDashboard(root: string, stamp: DashStamp, opts: { force?: boolean; maxUnchangedMs?: number } = {}): Promise<boolean> {
  const sig = dashboardFingerprint(root);
  if (!opts.force && stamp.sig === sig && Date.now() - stamp.at < (opts.maxUnchangedMs ?? DASH_MAX_UNCHANGED_MS)) return false;
  const r = await runToolAsync(root, "build-dashboard", ["--repo-root", root], { capture: true });
  if (r.status !== 0) return false;
  stamp.sig = sig;
  stamp.at = Date.now();
  return true;
}
