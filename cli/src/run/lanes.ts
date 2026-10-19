import { spawnSync } from "node:child_process";
import { appendFileSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { UsageError } from "../args";
import { contentHash, readJson, writeJson } from "../fsutil";
import { runTool, runToolAsync } from "../platform";
import { type DashStamp, rebuildDashboard } from "./dashstale";

/**
 * Dependency-driven scheduling of the per-spec states, used by `kcc run`.
 *
 * The driver (`kcc-run`) stays one sequential run per folder. After the shared states (IDEA .. SPECS),
 * every spec whose dependencies are merged runs `kcc-run --input SPEC-X --until 17` in its own lane
 * (`.kcc-lanes/SPEC-X`), so independent specs run at the same time and dependent ones wait.
 *
 * In a git workspace (the normal case: repo-bootstrap makes one) a lane is a **git worktree** on the branch
 * `spec/SPEC-X`, cut from the workspace HEAD: one repository, one object store, the lane's commits on the
 * spec branch the git-workflow protocol names. A finished lane is merged back with `git merge` (a real
 * three-way merge; `.gitignore` and the shared indexes merge as unions) and the worktree is removed. A
 * conflict is a git conflict, reported with the files and the branch to merge by hand; nothing is dropped.
 * Round 13: the copy-based merge before this compared whole-file hashes and ended a clean walking skeleton
 * on a `.gitignore` both sides had touched.
 *
 * A workspace without git keeps the older lane: a private copy with a hash snapshot, merged file by file.
 * Lane events and attention items are appended to the workspace while a lane runs, so the one dashboard
 * shows every spec; the lane's files reach the workspace when it merges.
 */

export interface RoadmapRow {
  order: number;
  spec: string;
  dependsOn: string[];
  lane: string;
}

/** Reads the `## Execution Plan` table of a ROADMAP.md. */
export function parseRoadmap(text: string): RoadmapRow[] {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const start = lines.findIndex((l) => /^##\s+execution plan/i.test(l));
  if (start < 0) return [];
  const rows: RoadmapRow[] = [];
  let cols: string[] | undefined;
  for (const l of lines.slice(start + 1)) {
    if (/^##\s/.test(l)) break;
    if (!l.trim().startsWith("|")) continue;
    const cells = l.trim().replace(/^\||\|$/g, "").split(/(?<!\\)\|/).map((c) => c.trim());
    if (!cols) {
      cols = cells.map((c) => c.toLowerCase());
      continue;
    }
    if (cells.every((c) => /^:?-+:?$/.test(c))) continue;
    const at = (name: string): string => cells[cols!.findIndex((c) => c.startsWith(name))] ?? "";
    const order = Number(at("order"));
    const spec = /SPEC-\d+/.exec(at("spec"))?.[0];
    if (!Number.isFinite(order) || !spec) continue;
    rows.push({ order, spec, dependsOn: at("depends").match(/SPEC-\d+/g) ?? [], lane: at("lane") });
  }
  return rows;
}

/** Specs grouped by roadmap order, ascending. Specs of one group do not depend on each other. */
export function groupByOrder(rows: RoadmapRow[]): string[][] {
  const by = new Map<number, string[]>();
  for (const r of rows) by.set(r.order, [...(by.get(r.order) ?? []), r.spec]);
  return [...by.keys()].sort((a, b) => a - b).map((k) => by.get(k)!);
}

// ---------------------------------------------------------------- snapshots and merging

const SKIP_DIRS = new Set([".git", "node_modules", ".kcc-lane", ".kcc-lanes"]);
// coordination/NeedsAttention*.md is never copied or merged as a file: every lane writes its own, and syncNeedsAttention appends
// the lane's new sections to the workspace's one file (two lanes writing the same file would clash).
const SKIP_PREFIXES = ["coordination/run/", "coordination/gates/", "coordination/checkpoints/", "dashboard/", "coordination/NeedsAttention"];
const ATTENTION = "coordination/NeedsAttention.md";
/** Indexes and logs every lane touches; a clash on these is reported, not a failure. */
const SHARED_INDEXES = new Set(["specs/specs.md", "ideation/ideas.md", "progress.md", "memory/index.json", "memory/memory.md", "architecture/architecture.md"]);
const BACKCHANNEL = "coordination/backchannel.jsonl";

function skipped(rel: string): boolean {
  return SKIP_PREFIXES.some((p) => rel.startsWith(p));
}

/** A running lane creates and deletes files under us (vite writes vitest.config.ts.timestamp-*.mjs and removes it). */
const TRANSIENT = /\.timestamp-\d+-[0-9a-f]+\.(mjs|cjs|js)$/;

/** path (posix, relative) -> hash, for every file a lane may change. A file that vanishes mid-walk is skipped. */
export function snapshot(root: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (dir: string): void => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const full = join(dir, e.name);
      const rel = relative(root, full).split(sep).join("/");
      if (e.isDirectory()) {
        if (SKIP_DIRS.has(e.name) || skipped(rel + "/")) continue;
        walk(full);
      } else if (e.isFile() && !skipped(rel) && !TRANSIENT.test(e.name)) {
        try {
          out[rel] = contentHash(readFileSync(full));
        } catch {
          /* deleted or locked while we looked: it is not part of this snapshot */
        }
      }
    }
  };
  walk(root);
  return out;
}

function copyTree(from: string, to: string): void {
  const walk = (dir: string): void => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, e.name);
      const rel = relative(from, full).split(sep).join("/");
      if (e.isDirectory()) {
        if (SKIP_DIRS.has(e.name) || skipped(rel + "/")) continue;
        walk(full);
      } else if (e.isFile() && !skipped(rel)) {
        const dest = join(to, rel);
        mkdirSync(dirname(dest), { recursive: true });
        copyFileSync(full, dest);
      }
    }
  };
  walk(from);
}

export interface MergeResult {
  /** path -> content hash now in the workspace (null: removed); lets a repeated merge advance its base. */
  hashes?: Record<string, string | null>;
  applied: string[];
  deleted: string[];
  conflicts: string[];
  sharedSkipped: string[];
  events: number;
  /** NeedsAttention sections appended to the workspace's file. */
  attention?: number;
}

function nextEventNumber(file: string): number {
  if (!existsSync(file)) return 1;
  let max = 0;
  for (const l of readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = /"id"\s*:\s*"BC-(\d+)"/.exec(l);
    if (m) max = Math.max(max, Number(m[1]));
  }
  return max + 1;
}

/** Appends the lane's backchannel events that the main workspace has not seen yet, with fresh ids. */
export function syncBackchannel(main: string, lane: string): number {
  const laneBc = join(lane, BACKCHANNEL);
  const metaFile = join(lane, ".kcc-lane", "base.json");
  if (!existsSync(laneBc)) return 0;
  const meta = readJson<{ backchannelLines?: number; backchannelSynced?: number }>(metaFile) ?? {};
  const all = readFileSync(laneBc, "utf8").split(/\r?\n/).filter(Boolean);
  const cut = meta.backchannelSynced ?? meta.backchannelLines ?? 0;
  const fresh = all.slice(cut);
  if (!fresh.length) return 0;
  const mainBc = join(main, BACKCHANNEL);
  let n = nextEventNumber(mainBc);
  mkdirSync(dirname(mainBc), { recursive: true });
  for (const l of fresh) appendFileSync(mainBc, l.replace(/("id"\s*:\s*")BC-\d+(")/, `$1BC-${String(n++).padStart(5, "0")}$2`) + "\n");
  writeJson(metaFile, { ...meta, backchannelSynced: all.length });
  return fresh.length;
}

/** The `## [open|decided] ...` sections of a NeedsAttention.md, each with its trailing text; the header before the first one is dropped. */
function attentionSections(text: string): string[] {
  return text.replace(/\r\n/g, "\n").split(/^(?=## \[(?:open|decided)\])/m).filter((s) => /^## \[(?:open|decided)\]/.test(s));
}

/** Counts the sections of a NeedsAttention.md: all and open. */
export function attentionCounts(file: string): { items: number; open: number } {
  if (!existsSync(file)) return { items: 0, open: 0 };
  const s = attentionSections(readFileSync(file, "utf8"));
  return { items: s.length, open: s.filter((x) => x.startsWith("## [open]")).length };
}

const ATTENTION_HEADER =
  "# Needs attention\n\nWritten by kcc-run under --silent --assume, which never stops for a human: every gate is answered by policy and recorded here.\n\n" +
  "- status: decided = the run went on with the safest continuing choice; check the decision.\n" +
  "- status: open = the spec could not continue and was left; a human must act (the run finished everything else, exit code 7).\n\n";

/** Appends one item to the workspace's coordination/NeedsAttention.md (the same section format the drivers write). */
export function appendAttention(root: string, it: { spec: string; gate: string; status: "open" | "decided"; state?: string; decided: string; why: string; todo: string; links?: string }): void {
  const file = join(root, ATTENTION);
  const when = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  const flat = (s: string): string => s.replace(/\s+/g, " ").trim();
  mkdirSync(dirname(file), { recursive: true });
  if (!existsSync(file)) writeFileSync(file, ATTENTION_HEADER);
  const st = it.state ?? "";
  appendFileSync(
    file,
    `## [${it.status}] ${it.spec || "run"} | ${it.gate} | state ${st} | ${when}\n\n- when: ${when}\n- spec: ${it.spec || "run"}\n- state: ${st}\n- gate: ${it.gate}\n- status: ${it.status}\n- decided: ${flat(it.decided)}\n- why: ${flat(it.why)}\n- todo: ${flat(it.todo)}\n- links: ${flat(it.links ?? "")}\n\n`,
  );
  emit(root, "needs-attention", it.spec, { status: it.status, gate: it.gate, decided: flat(it.decided), reason: flat(it.why), todo: flat(it.todo), file: ATTENTION });
}

/** Appends the lane's NeedsAttention sections that the workspace has not seen yet (the lane's own file is never merged as a file). */
export function syncNeedsAttention(main: string, lane: string): number {
  const laneFile = join(lane, ATTENTION);
  if (!existsSync(laneFile)) return 0;
  const metaFile = join(lane, ".kcc-lane", "base.json");
  const meta = readJson<{ needsSynced?: number }>(metaFile) ?? {};
  const text = readFileSync(laneFile, "utf8");
  const all = attentionSections(text);
  const fresh = all.slice(meta.needsSynced ?? 0);
  if (!fresh.length) return 0;
  const mainFile = join(main, ATTENTION);
  mkdirSync(dirname(mainFile), { recursive: true });
  if (!existsSync(mainFile)) writeFileSync(mainFile, text.replace(/\r\n/g, "\n").slice(0, text.replace(/\r\n/g, "\n").indexOf(all[0]!)) || ATTENTION_HEADER);
  appendFileSync(mainFile, fresh.join(""));
  writeJson(metaFile, { ...meta, needsSynced: all.length });
  return fresh.length;
}

/** Copies the files a lane owns (its own spec folder and test results) into the main workspace as they change. */
export function syncOwned(main: string, lane: string, owned: string[]): number {
  if (!owned.length) return 0;
  let n = 0;
  const now = snapshot(lane);
  for (const [rel, hash] of Object.entries(now)) {
    if (!owned.some((p) => rel.startsWith(p))) continue;
    const mainFile = join(main, rel);
    try {
      if (existsSync(mainFile) && contentHash(readFileSync(mainFile)) === hash) continue;
      mkdirSync(dirname(mainFile), { recursive: true });
      copyFileSync(join(lane, rel), mainFile);
      n++;
    } catch {
      /* the lane changed the file under us; the next sync picks it up */
    }
  }
  return n;
}

/**
 * Brings one lane's changes back into the main workspace. Files under `owned` belong to this lane alone
 * (its spec folder, its test results) and are always taken from the lane; any other file the main
 * workspace changed since the lane was cut is a conflict and keeps the main copy.
 */
export function mergeLane(main: string, lane: string, base: Record<string, string>, owned: string[] = []): MergeResult {
  const res: MergeResult = { applied: [], deleted: [], conflicts: [], sharedSkipped: [], events: 0, hashes: {} };
  const now = snapshot(lane);
  const paths = new Set([...Object.keys(base), ...Object.keys(now)]);
  for (const rel of [...paths].sort()) {
    if (rel === BACKCHANNEL) continue;
    const before = base[rel];
    const after = now[rel];
    if (before === after) continue;
    const mainFile = join(main, rel);
    const mainHash = existsSync(mainFile) ? contentHash(readFileSync(mainFile)) : undefined;
    if (mainHash === after) continue;
    if (rel === ".gitignore" && after !== undefined) {
      // Ignore rules are a set: the lane's new lines are appended to the workspace file (the lane marker stays in the lane), and
      // two lanes that both add rules both merge. Nothing is dropped and nothing is reported as a conflict.
      const added = unionGitignore(mainFile, join(lane, rel));
      if (added) { res.applied.push(rel); res.hashes![rel] = contentHash(readFileSync(mainFile)); }
      continue;
    }
    if (mainHash !== before && !owned.some((p) => rel.startsWith(p))) {
      (SHARED_INDEXES.has(rel) ? res.sharedSkipped : res.conflicts).push(rel);
      continue;
    }
    if (after === undefined) {
      rmSync(mainFile, { force: true });
      res.deleted.push(rel);
      res.hashes![rel] = null;
    } else {
      mkdirSync(dirname(mainFile), { recursive: true });
      copyFileSync(join(lane, rel), mainFile);
      res.applied.push(rel);
      res.hashes![rel] = after ?? null;
    }
  }
  res.events = syncBackchannel(main, lane);
  res.attention = syncNeedsAttention(main, lane);
  return res;
}

// ---------------------------------------------------------------- dependency scheduler

export interface LaneState {
  /** needs-attention: a `--silent --assume` lane that could not continue and was parked (exit 7); the run went on without it. */
  status: "running" | "done" | "failed" | "merged" | "needs-attention";
  dir: string;
  exit?: number;
  reason?: string;
  started?: string;
  finished?: string;
}

/**
 * While specs run in their lanes the driver that wrote run.json has already stopped at `--until 9`, so the
 * run looked "stopped at PREFLIGHT" on the dashboard for hours. The scheduler owns the run's visible state
 * during that phase: running, at the earliest stage a lane is in, naming the lanes.
 */
export function mirrorRun(root: string, state: Record<string, { status: string; dir: string }>, running: Iterable<string>, extra?: { status: string; reason: string }): void {
  const file = join(root, "coordination", "run", "run.json");
  const run = readJson<Record<string, string>>(file);
  if (!run) return;
  const names = [...running];
  const stages = names
    .map((s) => Number(readJson<{ state?: string }>(join(state[s]?.dir ?? "", "coordination", "run", "run.json"))?.state))
    .filter((n) => Number.isFinite(n));
  if (extra) {
    run.status = extra.status;
    run.reason = extra.reason;
  } else if (names.length) {
    run.status = "running";
    run.reason = `specs running in lanes: ${names.join(", ")}`;
    if (stages.length) run.state = String(Math.min(...stages));
  }
  run.updated = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  try {
    writeJson(file, run);
  } catch {
    /* the run file is rewritten by the driver as well; a clash is retried at the next tick */
  }
}

/**
 * A spec built in a lane is not in the workspace until it merges, so for hours `src/` was empty and the dashboard showed
 * a spec's old bugs and test results. This brings the lane's work into the workspace as it happens: the same merge the lane
 * gets at the end (files the workspace changed meanwhile are left alone and reported), repeated while it runs.
 */
export function liveSyncLane(root: string, lane: string, spec: string): MergeResult | undefined {
  if (laneMode(lane) === "worktree") {
    // The lane's files live on its branch and in its folder (the dashboard reads lane folders); only its events and attention
    // items are shared while it runs. Nothing is copied into the workspace tree before the merge.
    try {
      return { applied: [], deleted: [], conflicts: [], sharedSkipped: [], events: syncBackchannel(root, lane), attention: syncNeedsAttention(root, lane) };
    } catch {
      return undefined;
    }
  }
  const base = readJson<{ base?: Record<string, string> }>(join(lane, ".kcc-lane", "base.json"))?.base;
  if (!base) return undefined;
  try {
    const res = mergeLane(root, lane, base, ownedPaths(root, spec));
    // What was merged is now the lane's new base: a later edit of the same file is the lane's change, not a clash.
    const metaFile = join(lane, ".kcc-lane", "base.json");
    const meta = readJson<{ base?: Record<string, string> }>(metaFile) ?? {};
    const next = { ...(meta.base ?? {}) };
    for (const [rel, h] of Object.entries(res.hashes ?? {})) {
      if (h === null) delete next[rel];
      else next[rel] = h;
    }
    const cur = readJson<Record<string, unknown>>(metaFile) ?? {};
    writeJson(metaFile, { ...cur, base: next });
    return res;
  } catch {
    return undefined;
  }
}

/** Every lane under .kcc-lanes/, for callers that do not hold the scheduler's state (the live dashboard). */
export function liveSyncAllLanes(root: string): void {
  const dir = join(root, ".kcc-lanes");
  if (!existsSync(dir)) return;
  for (const e of readdirSync(dir, { withFileTypes: true })) if (e.isDirectory()) liveSyncLane(root, join(dir, e.name), e.name);
}

export function lanesFile(root: string): string {
  return join(root, "coordination", "lanes.json");
}

/** Lanes live inside the workspace, in a hidden folder that is never committed and is removed after a merge. */
export function laneDir(root: string, spec: string): string {
  return join(root, ".kcc-lanes", spec);
}

function gitIn(dir: string, ...args: string[]): void {
  spawnSync("git", args, { cwd: dir, encoding: "utf8" });
}

const trustKey = (dir: string): string => resolve(dir).split(sep).join("/");

function claudeConfig(): { file: string; data?: { projects?: Record<string, Record<string, unknown>> } } {
  const file = join(homedir(), ".claude.json");
  return { file, data: readJson<{ projects?: Record<string, Record<string, unknown>> }>(file) };
}

/** True when Claude Code trusts the folder (permissions.allow is ignored in an untrusted folder). */
export function isTrusted(dir: string): boolean {
  const { data } = claudeConfig();
  const projects = data?.projects ?? {};
  const key = trustKey(dir).toLowerCase();
  return Object.entries(projects).some(([k, v]) => k.toLowerCase() === key && v?.hasTrustDialogAccepted === true);
}

/** Trust is not inherited by subfolders, so a lane gets the trust its workspace already has. */
export function trustFolder(dir: string): void {
  const { file, data } = claudeConfig();
  if (!data) return;
  const projects = (data.projects ??= {});
  const key = trustKey(dir);
  projects[key] = { allowedTools: [], mcpContextUris: [], mcpServers: {}, enabledMcpjsonServers: [], disabledMcpjsonServers: [], ...projects[key], hasTrustDialogAccepted: true };
  writeFileSync(file, JSON.stringify(data, null, 2));
}

/** Appends the lane's .gitignore lines the workspace file lacks (comments and blank lines travel with the first new rule after
 *  them; the lane marker `.kcc-lane/` never does). Returns the number of lines added. */
export function unionGitignore(mainFile: string, laneFile: string): number {
  const cur = existsSync(mainFile) ? readFileSync(mainFile, "utf8") : "";
  const have = new Set(cur.split(/\r?\n/).map((l) => l.trim()).filter(Boolean));
  const out: string[] = [];
  let pending: string[] = [];
  for (const raw of readFileSync(laneFile, "utf8").split(/\r?\n/)) {
    const l = raw.trim();
    if (l === "" || l.startsWith("#")) { pending.push(raw); continue; }
    if (l === ".kcc-lane/" || l === ".kcc-lane" || have.has(l)) { pending = []; continue; }
    out.push(...pending, raw); pending = []; have.add(l);
  }
  const rules = out.filter((l) => l.trim() && !l.trim().startsWith("#")).length;
  if (rules === 0) return 0;
  writeFileSync(mainFile, cur + (cur === "" || cur.endsWith("\n") ? "" : "\n") + out.join("\n") + "\n");
  return rules;
}

/** Adds a line to the folder's .gitignore when it is not there yet (the file is created when missing). */
export function ensureGitignore(dir: string, line: string): void {
  const f = join(dir, ".gitignore");
  const cur = existsSync(f) ? readFileSync(f, "utf8") : "";
  const bare = line.replace(/\/$/, "");
  if (cur.split(/\r?\n/).some((l) => l.trim() === line || l.trim() === bare)) return;
  writeFileSync(f, cur + (cur === "" || cur.endsWith("\n") ? "" : "\n") + line + "\n");
}

// ---------------------------------------------------------------- git worktree lanes

export interface GitResult { status: number; stdout: string; stderr: string }
/** Runs git in a folder; bookkeeping commits carry the framework identity so a workspace without user.name still works. */
export function git(dir: string, ...args: string[]): GitResult {
  const r = spawnSync("git", ["-c", "user.name=KCC", "-c", "user.email=kcc@local", "-c", "core.autocrlf=false", ...args], { cwd: dir, encoding: "utf8" });
  return { status: r.status ?? 1, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

/** A workspace where lanes can be worktrees: a git repository with at least one commit. */
export function isGitWorkspace(root: string): boolean {
  if (git(root, "rev-parse", "--is-inside-work-tree").stdout.trim() !== "true") return false;
  return git(root, "rev-parse", "--verify", "-q", "HEAD").status === 0;
}

/** The repository's common git dir (shared by every worktree), absolute. */
function gitCommonDir(root: string): string {
  const d = git(root, "rev-parse", "--git-common-dir").stdout.trim();
  return resolve(root, d || ".git");
}

function appendMissingLines(file: string, lines: string[]): void {
  const cur = existsSync(file) ? readFileSync(file, "utf8") : "";
  const have = new Set(cur.split(/\r?\n/).map((l) => l.trim()));
  const add = lines.filter((l) => !have.has(l));
  if (!add.length) return;
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, cur + (cur === "" || cur.endsWith("\n") ? "" : "\n") + add.join("\n") + "\n");
}

/** Union-merged files: both sides add lines, nobody edits the other's. The ignore file and the shared indexes. */
export const UNION_MERGE = [".gitignore", "specs/specs.md", "ideation/ideas.md", "progress.md", "memory/memory.md"];

/**
 * The repository-local settings a lane needs, written once (never into tracked files): the lane folders are excluded from
 * status everywhere, and the union-merged files get their merge driver.
 */
export function prepareRepoForLanes(root: string): void {
  const common = gitCommonDir(root);
  // The run's own state is never a commit's business, whatever the project's .gitignore says (the bookkeeping commits below add everything else).
  appendMissingLines(join(common, "info", "exclude"), [".kcc-lanes/", ".kcc-lane/", "coordination/run/", "coordination/gates/", "coordination/checkpoints/", "coordination/lanes.json", "coordination/backchannel.jsonl", "coordination/backchannel-*.jsonl", "dashboard/"]);
  appendMissingLines(join(common, "info", "attributes"), UNION_MERGE.map((f) => `${f} merge=union`));
}

/** The lane branch of a spec, as the git-workflow protocol names it. */
export function laneBranch(spec: string): string {
  return `spec/${spec}`;
}

/** Commits everything that is not ignored, when anything changed. Framework bookkeeping: hooks are not run for it. */
export function commitAll(dir: string, message: string): { committed: boolean; error?: string } {
  git(dir, "add", "-A");
  if (git(dir, "diff", "--cached", "--quiet").status === 0) return { committed: false };
  const r = git(dir, "commit", "-q", "--no-verify", "-m", message);
  return r.status === 0 ? { committed: true } : { committed: false, error: (r.stderr || r.stdout).trim() };
}

/** Folders and files git ignores that a lane still needs to run: the harness folders and the run's event log. */
const LANE_RUNTIME = [".claude", ".codex", ".opencode", ".agents", "ollama", "coordination/orchestrator.json", "coordination/orchestrator.md", BACKCHANNEL];
function copyRuntime(root: string, dir: string): void {
  for (const rel of LANE_RUNTIME) {
    const from = join(root, rel);
    const to = join(dir, rel);
    if (!existsSync(from) || existsSync(to)) continue;
    try {
      if (statSync(from).isDirectory()) copyTree(from, to);
      else { mkdirSync(dirname(to), { recursive: true }); copyFileSync(from, to); }
    } catch {
      /* a runtime file that vanished or is locked: the lane recreates what it needs */
    }
  }
}

export type LaneMode = "worktree" | "copy";
export interface LaneMeta { spec: string; mode?: LaneMode; branch?: string; base?: Record<string, string>; backchannelLines?: number; backchannelSynced?: number; needsSynced?: number }
export function laneMeta(lane: string): LaneMeta | undefined {
  return readJson<LaneMeta>(join(lane, ".kcc-lane", "base.json"));
}
export function laneMode(lane: string): LaneMode {
  return laneMeta(lane)?.mode === "worktree" ? "worktree" : "copy";
}

/** Removes a worktree lane (registration and folder); a plain folder is just removed. */
export function removeLane(root: string, dir: string): void {
  if (existsSync(dir) && laneMode(dir) === "worktree") git(root, "worktree", "remove", "--force", dir);
  rmSync(dir, { recursive: true, force: true });
  git(root, "worktree", "prune");
}

/**
 * Cuts a worktree lane: the workspace's uncommitted work is committed first (the lane must see every file the shared states
 * wrote), then `git worktree add -B spec/SPEC-X` from HEAD, then the ignored runtime files are copied in.
 * Returns undefined when the workspace cannot be committed (a hook or a lock); the caller falls back to a copy lane and says so.
 */
export function createWorktreeLane(root: string, spec: string, trust: boolean): { dir: string; base: Record<string, string> } | undefined {
  const dir = laneDir(root, spec);
  prepareRepoForLanes(root);
  const c = commitAll(root, `${spec}: workspace state before the lane (kcc)`);
  if (c.error) return undefined;
  if (existsSync(dir)) removeLane(root, dir);
  mkdirSync(dirname(dir), { recursive: true });
  const w = git(root, "worktree", "add", "-q", "-B", laneBranch(spec), dir, "HEAD");
  if (w.status !== 0) { rmSync(dir, { recursive: true, force: true }); return undefined; }
  copyRuntime(root, dir);
  const bc = join(dir, BACKCHANNEL);
  const backchannelLines = existsSync(bc) ? readFileSync(bc, "utf8").split(/\r?\n/).filter(Boolean).length : 0;
  mkdirSync(join(dir, ".kcc-lane"), { recursive: true });
  writeJson(join(dir, ".kcc-lane", "base.json"), { spec, mode: "worktree", branch: laneBranch(spec), backchannelLines });
  if (trust) trustFolder(dir);
  return { dir, base: {} };
}

/**
 * Merges a worktree lane: the lane's leftover edits are committed on its branch, the workspace's own leftovers on its branch,
 * then the spec branch is merged (fast-forward when nothing else moved, a merge commit otherwise). A conflict leaves the
 * workspace as it was (the merge is aborted) and names the files; the branch keeps the lane's work for a merge by hand.
 */
export function mergeWorktreeLane(root: string, lane: string, spec: string): MergeResult {
  const res: MergeResult = { applied: [], deleted: [], conflicts: [], sharedSkipped: [], events: 0, hashes: {} };
  const branch = laneMeta(lane)?.branch ?? laneBranch(spec);
  const lc = commitAll(lane, `${spec}: lane checkpoint (kcc)`);
  if (lc.error) { res.conflicts.push(`(lane commit failed: ${lc.error.split(/\r?\n/)[0]})`); return res; }
  const wc = commitAll(root, `${spec}: workspace state before merging the lane (kcc)`);
  if (wc.error) { res.conflicts.push(`(workspace commit failed: ${wc.error.split(/\r?\n/)[0]})`); return res; }
  const before = git(root, "rev-parse", "HEAD").stdout.trim();
  const m = git(root, "merge", "--no-edit", "-m", `${spec}: merge lane ${branch} (kcc)`, branch);
  if (m.status !== 0) {
    const files = git(root, "diff", "--name-only", "--diff-filter=U").stdout.split(/\r?\n/).filter(Boolean);
    git(root, "merge", "--abort");
    res.conflicts.push(...(files.length ? files : [`(git merge ${branch} failed: ${(m.stderr || m.stdout).trim().split(/\r?\n/)[0]})`]));
  } else {
    const changed = git(root, "diff", "--name-status", `${before}..HEAD`).stdout.split(/\r?\n/).filter(Boolean);
    for (const l of changed) {
      const [st, ...rest] = l.split("\t");
      const rel = rest[rest.length - 1] ?? "";
      if (!rel) continue;
      if (st?.startsWith("D")) res.deleted.push(rel); else res.applied.push(rel);
    }
  }
  res.events = syncBackchannel(root, lane);
  res.attention = syncNeedsAttention(root, lane);
  return res;
}

/** Cuts a lane: a worktree in a git workspace, else a copy with its own git baseline and base snapshot. */
export function createLane(root: string, spec: string, trust: boolean): { dir: string; base: Record<string, string> } {
  if (isGitWorkspace(root)) {
    const w = createWorktreeLane(root, spec, trust);
    if (w) return w;
  }
  return createCopyLane(root, spec, trust);
}

/** The copy lane (a workspace without git): a copy of the workspace with its own git baseline and base snapshot. */
export function createCopyLane(root: string, spec: string, trust: boolean): { dir: string; base: Record<string, string> } {
  const dir = laneDir(root, spec);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  copyTree(root, dir);
  // The base is the workspace as copied. Round 13: the snapshot used to be taken after the marker line below was added, so the
  // lane's .gitignore never matched the workspace copy and the first implementer that added an ignore rule ended the run with a
  // "merge conflict: .gitignore" after a clean verification.
  const base = snapshot(dir);
  // The lane's own git repo must not see its marker folder as an untracked change (R10: implementers had to step around it).
  ensureGitignore(dir, ".kcc-lane/");
  const bc = join(dir, BACKCHANNEL);
  const backchannelLines = existsSync(bc) ? readFileSync(bc, "utf8").split(/\r?\n/).filter(Boolean).length : 0;
  mkdirSync(join(dir, ".kcc-lane"), { recursive: true });
  writeJson(join(dir, ".kcc-lane", "base.json"), { spec, mode: "copy", base, backchannelLines });
  gitIn(dir, "init", "-q");
  gitIn(dir, "config", "user.email", "kcc-lane@example.com");
  gitIn(dir, "config", "user.name", "KCC lane");
  gitIn(dir, "config", "core.autocrlf", "false");
  gitIn(dir, "add", "-A", "-f", "--", ".", ":!.kcc-lane");
  gitIn(dir, "commit", "-q", "-m", `lane ${spec} baseline`);
  if (trust) trustFolder(dir);
  return { dir, base };
}

export function findRoadmap(root: string): string | undefined {
  const specs = join(root, "specs");
  if (!existsSync(specs)) return undefined;
  for (const d of readdirSync(specs, { withFileTypes: true })) {
    const f = join(specs, d.name, "ROADMAP.md");
    if (d.isDirectory() && existsSync(f)) return f;
  }
  return undefined;
}

/** The paths only this spec's lane writes: its spec folder and its test results. */
export function ownedPaths(root: string, spec: string): string[] {
  const out: string[] = [];
  const specs = join(root, "specs");
  if (existsSync(specs)) {
    for (const g of readdirSync(specs, { withFileTypes: true })) {
      if (!g.isDirectory()) continue;
      for (const d of readdirSync(join(specs, g.name), { withFileTypes: true })) {
        if (d.isDirectory() && (d.name === spec || d.name.startsWith(spec + "-"))) out.push(`specs/${g.name}/${d.name}/`);
      }
      const idea = /^(IDEA-\d+)/.exec(g.name)?.[1];
      if (idea) out.push(`TestResults/${idea}/${spec}/`);
    }
  }
  return out;
}

/** A spec is ready when every spec it depends on (inside this roadmap) has been merged. */
export function readySpecs(rows: RoadmapRow[], state: Record<string, LaneState | undefined>): string[] {
  const known = new Set(rows.map((r) => r.spec));
  return rows
    .filter((r) => !state[r.spec])
    .filter((r) => r.dependsOn.filter((d) => known.has(d) && d !== r.spec).every((d) => state[d]?.status === "merged"))
    .map((r) => r.spec);
}

function emit(root: string, kind: string, spec: string, payload: Record<string, unknown>): void {
  const file = join(root, BACKCHANNEL);
  const n = nextEventNumber(file);
  const ev = { ts: new Date().toISOString().replace(/\.\d+Z$/, "Z"), id: `BC-${String(n).padStart(5, "0")}`, from: "kcc-scheduler", to: "broadcast", kind, spec, session: null, payload: { ...payload, source: "kcc-scheduler" } };
  mkdirSync(dirname(file), { recursive: true });
  appendFileSync(file, JSON.stringify(ev) + "\n");
}

export interface ScheduleOptions {
  /** kcc-run flags every lane gets (--fasttrack, --silent, --assume, --depthlevel N, ...). */
  passthrough: string[];
  /** Build lanes (IMPLEMENT .. REVIEW) at the same time. */
  maxParallel: number;
  /** Fan-out states (WRITE, PLAN) at the same time; unset = unlimited (short, file-disjoint planning tasks). */
  maxFanout?: number;
  /** Seconds between live syncs of lane progress into the main workspace and its dashboard. */
  syncSeconds?: number;
  /** Runs a kcc-run in a folder; injectable for tests. */
  runDriver?: (dir: string, args: string[]) => Promise<number>;
  log?: (line: string) => void;
  /** Last state a lane runs (kcc-run --until); 17 (REVIEW) by default, the PLAN state for the planning phase. */
  until?: number;
  /** State a fresh lane starts at (kcc-run --from), e.g. the state after PLAN once every plan exists. */
  from?: number;
  /** Specs parked as needs-attention earlier in this run (the fan-out phase): they stay parked instead of being retried at once. */
  hold?: string[];
  /** Filled on return: the specs parked as needs-attention. */
  report?: { attention: string[] };
  /** Run only these specs (default: every spec of the roadmap). */
  only?: string[];
  /** Planning needs no other spec's output, so `Depends on` is ignored and every spec starts at once (up to maxFanout, unlimited by default). */
  independent?: boolean;
  /** Set (to the state's name) for a fan-out state: lane state stays in memory (the exit check says what is done, the lane folder what to resume). */
  fanout?: string;
}

export interface FanoutState {
  id: number;
  name: string;
  /** The state's exit check (tool and PowerShell-style args with {SPEC}), run per spec to see what is still to do. */
  check?: { tool: string; args?: string[] };
}

/**
 * The per-spec states the table marks `"fanout": true` (WRITE and PLAN in fast track, PLAN in the full table), in table
 * order, and the state after the last of them. Each one is run for all specs at the same time before the build lanes start.
 */
export function fanoutStates(root: string, fasttrack: boolean): { states: FanoutState[]; after?: number } {
  const kernel = join(root, ".KCC", "kernel");
  const file = fasttrack && existsSync(join(kernel, "auto-states-fasttrack.json")) ? join(kernel, "auto-states-fasttrack.json") : join(kernel, "auto-states.json");
  const all = readJson<{ states?: (FanoutState & { scope: string; fanout?: boolean })[] }>(file)?.states ?? [];
  const states = all.filter((s) => s.scope === "spec" && s.fanout);
  const last = states.length ? all.indexOf(states[states.length - 1]! as never) : -1;
  return { states, after: last >= 0 ? all[last + 1]?.id : undefined };
}

/** `-RunProfile` (PowerShell spelling in the state table) as `--run-profile`, the spelling runTool takes everywhere. */
function toolArg(a: string, spec: string): string {
  const v = a.replaceAll("{SPEC}", spec);
  return /^-[A-Za-z]/.test(v) ? "--" + v.slice(1).replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase() : v;
}

/**
 * Specs of the roadmap for which this state is not done: its exit check fails in the workspace, or a lane is left over to
 * resume. A left-over lane belongs to the state it stopped at; one that is past this state belongs to a later one, except past
 * the last fan-out state, where only its merge is left.
 */
export async function specsToRun(root: string, state: FanoutState, last = true): Promise<string[]> {
  const roadmap = findRoadmap(root);
  if (!roadmap) return [];
  const specs = parseRoadmap(readFileSync(roadmap, "utf8")).map((r) => r.spec);
  // The exit checks of the specs are independent and read-only, and each is a PowerShell or bash process that costs seconds to start:
  // run them side by side (a few at a time) instead of one after the other.
  const todo = new Array<boolean>(specs.length).fill(false);
  let next = 0;
  const worker = async (): Promise<void> => {
    for (let i = next++; i < specs.length; i = next++) {
      const spec = specs[i]!;
      const leftover = readJson<{ state?: string }>(join(laneDir(root, spec), "coordination", "run", "run.json"));
      if (leftover) { todo[i] = last || !(Number(leftover.state) > state.id); continue; }
      if (!state.check || state.check.tool.startsWith("internal:")) { todo[i] = true; continue; }
      const r = await runToolAsync(root, state.check.tool, [...(state.check.args ?? []).map((a) => toolArg(a, spec)), "--json"], { capture: true });
      todo[i] = r.status !== 0;
    }
  };
  await Promise.all(Array.from({ length: Math.min(4, specs.length) }, () => worker()));
  return specs.filter((_, i) => todo[i]);
}

export interface FanoutResult {
  /** 0 when every spec went through every fan-out state (or the table has none), 4 when a lane stopped, 7 when only parked specs are left (silent). */
  code: number;
  /** The state after the last fan-out state: where the build lanes start, so nothing is redone or re-approved. */
  after?: number;
  /** Specs a --silent --assume lane parked as needs-attention (exit 7): skipped by the later states and by the build lanes of this run. */
  attention?: string[];
}

/**
 * The fan-out states (a spec-writer per spec, then a planner per spec), each for all specs at the same time (no limit unless
 * maxFanout is set; maxParallel bounds only the build lanes), every one in its own lane and ignoring `Depends on`: writing or planning one spec needs only its own files,
 * the architecture and the dialects, never another spec's output. A spec whose exit check already passes is not run
 * again; a failure retries only its own spec (its lane keeps the attempt count and the loop gate).
 */
export async function fanoutSpecs(root: string, o: Pick<ScheduleOptions, "passthrough" | "maxParallel" | "maxFanout" | "syncSeconds" | "runDriver" | "log">): Promise<FanoutResult> {
  const { states, after } = fanoutStates(root, o.passthrough.includes("--fasttrack"));
  const parked: string[] = [];
  for (const s of states) {
    const todo = (await specsToRun(root, s, s === states[states.length - 1])).filter((x) => !parked.includes(x));
    if (!todo.length) continue;
    (o.log ?? ((l: string) => console.log(l)))(`kcc: state ${s.id} ${s.name} for ${todo.length} spec(s) at the same time (${o.maxFanout ? `up to ${o.maxFanout}` : "no limit"})`);
    const report = { attention: [] as string[] };
    const code = await scheduleSpecs(root, { ...o, until: s.id, independent: true, fanout: s.name, only: todo, report, hold: parked });
    for (const a of report.attention) if (!parked.includes(a)) parked.push(a);
    if (code !== 0 && code !== 7) return parked.length ? { code, after, attention: parked } : { code, after };
  }
  return parked.length ? { code: 7, after, attention: parked } : { code: 0, after };
}

/**
 * Runs the per-spec states (PLAN .. REVIEW) of every spec as soon as its dependencies are merged.
 * Independent specs run at the same time, each in its own lane; a chain of dependencies runs one
 * after another. Nothing chooses "parallel" or "sequential": the roadmap's dependencies decide.
 * Returns 0 when every spec was merged, 4 when a lane stopped (gate, failure, or merge conflict).
 */
export async function scheduleSpecs(root: string, o: ScheduleOptions): Promise<number> {
  const log = o.log ?? ((l: string) => console.log(l));
  const roadmap = findRoadmap(root);
  if (!roadmap) throw new UsageError("no specs/IDEA-*/ROADMAP.md: the shared states must finish first");
  const all = parseRoadmap(readFileSync(roadmap, "utf8"));
  if (!all.length) throw new UsageError(`no '## Execution Plan' rows in ${roadmap}`);
  const what = o.fanout ? o.fanout.toLowerCase() : "spec";
  const rows = all.filter((r) => !o.only || o.only.includes(r.spec)).map((r) => (o.independent ? { ...r, dependsOn: [] } : r));
  const stateFile = lanesFile(root);
  const state = (o.fanout ? undefined : readJson<Record<string, LaneState>>(stateFile)) ?? {};
  // A fan-out state keeps no lane state of its own, but the file's presence is what lets a lane's dashboard refresh the workspace's.
  if (o.fanout && !existsSync(stateFile)) writeJson(stateFile, {});
  const save = (): void => {
    if (!o.fanout) writeJson(stateFile, state);
  };
  const trust = isTrusted(root);
  const drive = o.runDriver ?? (async (dir: string, args: string[]) => {
    const r = await runToolAsync(dir, "kcc-run", args);
    writeFileSync(join(dir, ".kcc-lane", "run.out"), r.stdout + r.stderr);
    return r.status;
  });

  // A lane that stopped earlier (gate, failure, parked as needs-attention) is resumed, not recreated. A spec parked in this very
  // run (o.hold, from the fan-out phase) stays parked: retrying it at once would only repeat the failure.
  for (const [spec, lane] of Object.entries(state)) {
    if (lane.status === "failed" || lane.status === "running" || (lane.status === "needs-attention" && !o.hold?.includes(spec))) delete state[spec];
  }
  for (const spec of o.hold ?? []) if (rows.some((r) => r.spec === spec)) state[spec] ??= { status: "needs-attention", dir: laneDir(root, spec), reason: "parked in an earlier phase of this run" };
  const silent = o.passthrough.includes("--silent");
  const resumable = new Set(rows.map((r) => r.spec).filter((s) => existsSync(join(laneDir(root, s), "coordination", "run", "run.json"))));
  const deps = rows.map((r) => `${r.spec}${r.dependsOn.length ? " <- " + r.dependsOn.join(", ") : ""}`).join(" | ");
  log(o.fanout ? `kcc: ${o.fanout}: ${rows.map((r) => r.spec).join(", ")} (${o.maxFanout ? `up to ${o.maxFanout}` : "no limit"} at the same time, no dependency order)` : `kcc: specs scheduled by dependency: ${deps}`);

  // Only the build lanes are bounded by --max-parallel; a fan-out state runs every spec at once unless --max-fanout says otherwise.
  const cap = o.fanout ? (o.maxFanout ?? Number.POSITIVE_INFINITY) : o.maxParallel;
  const running = new Map<string, Promise<void>>();
  const start = (spec: string): void => {
    const owned = ownedPaths(root, spec);
    let dir = laneDir(root, spec);
    let base: Record<string, string>;
    const resume = resumable.has(spec);
    if (resume) base = readJson<{ base: Record<string, string> }>(join(dir, ".kcc-lane", "base.json"))?.base ?? {};
    else ({ dir, base } = createLane(root, spec, trust));
    state[spec] = { status: "running", dir, started: new Date().toISOString() };
    save();
    emit(root, "lane-started", spec, { resumed: resume });
    log(`kcc: ${spec} started${resume ? " (resumed)" : ""}`);
    const args = resume ? ["--resume", ...o.passthrough] : ["--input", spec, ...o.passthrough, ...(o.from !== undefined ? ["--from", String(o.from)] : [])];
    const lanePromise = (async () => {
      // A fan-out lane whose gate was answered with `kcc run --lane` has already run through its state: only the merge is left.
      const past = o.fanout && resume && Number(readJson<{ state?: string }>(join(dir, "coordination", "run", "run.json"))?.state) > (o.until ?? 17);
      const code = past ? 0 : await drive(dir, [...args, "--until", String(o.until ?? 17), "--repo-root", dir]);
      const lane = state[spec]!;
      lane.exit = code;
      lane.finished = new Date().toISOString();
      if (code !== 0) {
        const r = readJson<{ gate_id?: string; gate_name?: string; reason?: string; state?: string }>(join(dir, "coordination", "run", "run.json"));
        // Exit 7: a --silent --assume lane that could not continue and was parked (its NeedsAttention item says why); anything else is a stop.
        lane.status = code === 7 ? "needs-attention" : "failed";
        lane.reason = r?.gate_id ? `paused at gate ${r.gate_id} (${r.gate_name}) in state ${r.state}` : r?.reason || `kcc-run exited ${code}`;
        // A stopped worktree lane keeps its work on its branch (committed here so nothing is lost); a stopped copy lane is merged
        // right now so the workspace never lags it. A file both sides changed is a conflict: reported, never dropped.
        if (laneMode(dir) === "worktree") {
          const c = commitAll(dir, `${spec}: lane checkpoint (kcc)`);
          if (c.error) log(`kcc: ${spec}: the lane's work could not be committed on ${laneBranch(spec)}: ${c.error.split(/\r?\n/)[0]}`);
        }
        const m = liveSyncLane(root, dir, spec);
        if (!m) {
          syncOwned(root, dir, owned);
          syncBackchannel(root, dir);
          syncNeedsAttention(root, dir);
        } else if (m.conflicts.length) {
          lane.reason += `; merge conflict: ${m.conflicts.join(", ")}`;
          if (silent) appendAttention(root, { spec, gate: "merge-conflict", status: "open", decided: "kept the workspace copy of the files both sides changed", why: `the stopped lane and the workspace both changed: ${m.conflicts.join(", ")}`, todo: `compare each file with ${laneDir(root, spec)}/<file> and merge by hand`, links: laneDir(root, spec) });
        }
        if (silent && code !== 7 && code !== 0) appendAttention(root, { spec, gate: "lane-stopped", status: "open", decided: "the lane stopped and the run went on with the other specs", why: lane.reason ?? `kcc-run exited ${code}`, todo: `see ${join(dir, "coordination", "run", "logs")}; fix the cause and run: kcc run --resume`, links: laneDir(root, spec) });
        emit(root, "lane-blocked", spec, { exit: code, reason: lane.reason });
        log(`kcc: ${spec} stopped: ${lane.reason}`);
      } else {
        const worktree = laneMode(dir) === "worktree";
        // A worktree lane is merged by git; a copy lane against the base its live syncs advanced, not the one it started with.
        const m = worktree
          ? mergeWorktreeLane(root, dir, spec)
          : mergeLane(root, dir, readJson<{ base?: Record<string, string> }>(join(dir, ".kcc-lane", "base.json"))?.base ?? base, owned);
        if (m.conflicts.length) {
          lane.status = "failed";
          lane.reason = `merge conflict: ${m.conflicts.join(", ")}`;
          const todo = worktree
            ? `in the workspace run: git merge ${laneBranch(spec)} ; resolve the files, commit, then: kcc run --resume`
            : `compare each file with ${laneDir(root, spec)}/<file>, merge by hand, then: kcc run --resume`;
          if (silent) appendAttention(root, { spec, gate: "merge-conflict", status: "open", decided: worktree ? `the merge of ${laneBranch(spec)} was aborted; the workspace is unchanged and the lane's work is on its branch` : "kept the workspace copy of the files both sides changed; the lane is kept", why: `the lane and the workspace both changed: ${m.conflicts.join(", ")}`, todo, links: laneDir(root, spec) });
          emit(root, "lane-blocked", spec, { reason: lane.reason });
          log(`kcc: ${spec} CONFLICT, these files changed in the workspace and in the lane: ${m.conflicts.join(", ")}`);
        } else {
          lane.status = "merged";
          emit(root, "lane-merged", spec, { files: m.applied.length, removed: m.deleted.length, events: m.events, mode: worktree ? "worktree" : "copy" });
          log(`kcc: ${spec} merged (${m.applied.length} files, ${m.events} events)`);
          removeLane(root, dir);
        }
      }
      save();
    })();
    // Removed here, not inside the lane: a lane that needs no driver finishes before it is registered and would stay "running" for ever.
    running.set(spec, lanePromise);
    void lanePromise.finally(() => running.delete(spec));
  };

  const dashStamp: DashStamp = { sig: "", at: 0 };
  const tick = async (): Promise<void> => {
    await Bun.sleep((o.syncSeconds ?? 20) * 1000);
    // The sync is a convenience copy; an error in it must never take the scheduler (and the lanes it supervises) down.
    try {
      for (const spec of running.keys()) {
        const lane = state[spec];
        if (!lane) continue;
        liveSyncLane(root, lane.dir, spec);
      }
      mirrorRun(root, state, running.keys());
      // rebuilt only when a file it reads changed (or the last build is a minute old): most ticks find nothing new
      if (!o.runDriver) await rebuildDashboard(root, dashStamp);
    } catch (e) {
      log(`kcc: lane sync skipped this round: ${(e as Error).message}`);
    }
  };

  for (;;) {
    const blocked = new Set(Object.entries(state).filter(([, l]) => l.status === "failed").map(([s]) => s));
    for (const spec of readySpecs(rows, state)) {
      if (running.size >= cap || blocked.has(spec)) break;
      start(spec);
    }
    if (!running.size) break;
    mirrorRun(root, state, running.keys());
    await Promise.race([...running.values(), tick()]);
  }
  if (!o.runDriver) runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
  const stopped = rows.filter((r) => state[r.spec]?.status !== "merged").map((r) => r.spec);
  if (!stopped.length) {
    mirrorRun(root, state, [], { status: "running", reason: o.fanout ? `${o.fanout} done for every spec` : "all specs merged; closing the run" });
    return 0;
  }
  const parked = stopped.filter((s) => state[s]?.status === "needs-attention");
  if (o.report) o.report.attention = parked;
  // A --silent --assume run never stops for a human: a spec that waits on a parked spec is parked with it, and the run ends with exit 7
  // (items need a human) instead of 4 (paused at a gate). The parked specs of a fan-out phase are kept for the build phase.
  if (silent || (parked.length && stopped.every((s) => !state[s] || state[s]!.status === "needs-attention"))) {
    if (!o.fanout) {
      for (const s of stopped) {
        if (state[s]) continue;
        const dep = rows.find((r) => r.spec === s)?.dependsOn.find((d) => state[d] && state[d]!.status !== "merged");
        state[s] = { status: "needs-attention", dir: laneDir(root, s), reason: dep ? `waits for ${dep}, which needs attention` : "waits for a spec that needs attention" };
      }
      save();
    } else if (parked.length) {
      const cur = readJson<Record<string, LaneState>>(stateFile) ?? {};
      for (const s of parked) cur[s] = state[s]!;
      writeJson(stateFile, cur);
    }
    mirrorRun(root, state, [], { status: "running", reason: `${what}s parked as needs-attention: ${stopped.join(", ")}` });
    for (const s of stopped) log(`kcc: ${s} needs attention: ${state[s]?.reason ?? "stopped"}. See coordination/NeedsAttention.md`);
    return 7;
  }
  mirrorRun(root, state, [], { status: "stopped", reason: `${what}s need attention: ${stopped.join(", ")}` });
  for (const s of stopped) {
    const lane = state[s];
    log(lane ? `kcc: ${s} needs attention: ${lane.reason ?? lane.status}. Answer with: kcc run --lane ${s} --answer <choice>, then kcc run --resume` : `kcc: ${s} waits for its dependencies`);
  }
  return 4;
}
