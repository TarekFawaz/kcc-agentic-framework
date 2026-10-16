import { spawnSync } from "node:child_process";
import { appendFileSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { UsageError } from "../args";
import { contentHash, readJson, writeJson } from "../fsutil";
import { runTool, runToolAsync } from "../platform";

/**
 * Dependency-driven scheduling of the per-spec states, used by `kcc run`.
 *
 * The driver (`kcc-run`) stays one sequential run per folder. After the shared states (IDEA .. SPECS),
 * every spec whose dependencies are merged runs `kcc-run --input SPEC-X --until 17` in its own lane
 * (`.kcc-lanes/SPEC-X`, a private copy with its own run state), so independent specs run at the same
 * time and dependent ones wait. A finished lane is merged back and removed; a file that both the lane
 * and the workspace changed is a conflict, never silently overwritten. Lane progress (its spec folder,
 * test results, backchannel events) is copied into the workspace while it runs, so the one dashboard
 * shows every spec.
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
const SKIP_PREFIXES = ["coordination/run/", "coordination/gates/", "coordination/checkpoints/", "dashboard/"];
/** Indexes and logs every lane touches; a clash on these is reported, not a failure. */
const SHARED_INDEXES = new Set(["specs/specs.md", "ideation/ideas.md", "progress.md", "memory/index.json", "memory/memory.md", "architecture/architecture.md"]);
const BACKCHANNEL = "coordination/backchannel.jsonl";

function skipped(rel: string): boolean {
  return SKIP_PREFIXES.some((p) => rel.startsWith(p));
}

/** path (posix, relative) -> hash, for every file a lane may change. */
export function snapshot(root: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (dir: string): void => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, e.name);
      const rel = relative(root, full).split(sep).join("/");
      if (e.isDirectory()) {
        if (SKIP_DIRS.has(e.name) || skipped(rel + "/")) continue;
        walk(full);
      } else if (e.isFile() && !skipped(rel)) {
        out[rel] = contentHash(readFileSync(full));
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
  applied: string[];
  deleted: string[];
  conflicts: string[];
  sharedSkipped: string[];
  events: number;
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

/** Copies the files a lane owns (its own spec folder and test results) into the main workspace as they change. */
export function syncOwned(main: string, lane: string, owned: string[]): number {
  if (!owned.length) return 0;
  let n = 0;
  const now = snapshot(lane);
  for (const [rel, hash] of Object.entries(now)) {
    if (!owned.some((p) => rel.startsWith(p))) continue;
    const mainFile = join(main, rel);
    if (existsSync(mainFile) && contentHash(readFileSync(mainFile)) === hash) continue;
    mkdirSync(dirname(mainFile), { recursive: true });
    copyFileSync(join(lane, rel), mainFile);
    n++;
  }
  return n;
}

/**
 * Brings one lane's changes back into the main workspace. Files under `owned` belong to this lane alone
 * (its spec folder, its test results) and are always taken from the lane; any other file the main
 * workspace changed since the lane was cut is a conflict and keeps the main copy.
 */
export function mergeLane(main: string, lane: string, base: Record<string, string>, owned: string[] = []): MergeResult {
  const res: MergeResult = { applied: [], deleted: [], conflicts: [], sharedSkipped: [], events: 0 };
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
    if (mainHash !== before && !owned.some((p) => rel.startsWith(p))) {
      (SHARED_INDEXES.has(rel) ? res.sharedSkipped : res.conflicts).push(rel);
      continue;
    }
    if (after === undefined) {
      rmSync(mainFile, { force: true });
      res.deleted.push(rel);
    } else {
      mkdirSync(dirname(mainFile), { recursive: true });
      copyFileSync(join(lane, rel), mainFile);
      res.applied.push(rel);
    }
  }
  res.events = syncBackchannel(main, lane);
  return res;
}

// ---------------------------------------------------------------- dependency scheduler

export interface LaneState {
  status: "running" | "done" | "failed" | "merged";
  dir: string;
  exit?: number;
  reason?: string;
  started?: string;
  finished?: string;
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

/** Cuts a lane: a copy of the workspace with its own git baseline and base snapshot. */
export function createLane(root: string, spec: string, trust: boolean): { dir: string; base: Record<string, string> } {
  const dir = laneDir(root, spec);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  copyTree(root, dir);
  const base = snapshot(dir);
  const bc = join(dir, BACKCHANNEL);
  const backchannelLines = existsSync(bc) ? readFileSync(bc, "utf8").split(/\r?\n/).filter(Boolean).length : 0;
  mkdirSync(join(dir, ".kcc-lane"), { recursive: true });
  writeJson(join(dir, ".kcc-lane", "base.json"), { spec, base, backchannelLines });
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
  maxParallel: number;
  /** Seconds between live syncs of lane progress into the main workspace and its dashboard. */
  syncSeconds?: number;
  /** Runs a kcc-run in a folder; injectable for tests. */
  runDriver?: (dir: string, args: string[]) => Promise<number>;
  log?: (line: string) => void;
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
  const rows = parseRoadmap(readFileSync(roadmap, "utf8"));
  if (!rows.length) throw new UsageError(`no '## Execution Plan' rows in ${roadmap}`);
  const stateFile = lanesFile(root);
  const state = readJson<Record<string, LaneState>>(stateFile) ?? {};
  const save = (): void => writeJson(stateFile, state);
  const trust = isTrusted(root);
  const drive = o.runDriver ?? (async (dir: string, args: string[]) => {
    const r = await runToolAsync(dir, "kcc-run", args);
    writeFileSync(join(dir, ".kcc-lane", "run.out"), r.stdout + r.stderr);
    return r.status;
  });

  // A lane that stopped earlier (gate, failure) is resumed, not recreated.
  for (const [spec, lane] of Object.entries(state)) {
    if (lane.status === "failed" || lane.status === "running") delete state[spec];
  }
  const resumable = new Set(rows.map((r) => r.spec).filter((s) => existsSync(join(laneDir(root, s), "coordination", "run", "run.json"))));
  const deps = rows.map((r) => `${r.spec}${r.dependsOn.length ? " <- " + r.dependsOn.join(", ") : ""}`).join(" | ");
  log(`kcc: specs scheduled by dependency: ${deps}`);

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
    const args = resume ? ["--resume", ...o.passthrough] : ["--input", spec, ...o.passthrough];
    running.set(spec, (async () => {
      const code = await drive(dir, [...args, "--until", "17", "--repo-root", dir]);
      const lane = state[spec]!;
      lane.exit = code;
      lane.finished = new Date().toISOString();
      if (code !== 0) {
        const r = readJson<{ gate_id?: string; gate_name?: string; reason?: string; state?: string }>(join(dir, "coordination", "run", "run.json"));
        lane.status = "failed";
        lane.reason = r?.gate_id ? `paused at gate ${r.gate_id} (${r.gate_name}) in state ${r.state}` : r?.reason || `kcc-run exited ${code}`;
        syncOwned(root, dir, owned);
        syncBackchannel(root, dir);
        emit(root, "lane-blocked", spec, { exit: code, reason: lane.reason });
        log(`kcc: ${spec} stopped: ${lane.reason}`);
      } else {
        const m = mergeLane(root, dir, base, owned);
        if (m.conflicts.length) {
          lane.status = "failed";
          lane.reason = `merge conflict: ${m.conflicts.join(", ")}`;
          emit(root, "lane-blocked", spec, { reason: lane.reason });
          log(`kcc: ${spec} CONFLICT, these files changed in the workspace and in the lane: ${m.conflicts.join(", ")}`);
        } else {
          lane.status = "merged";
          emit(root, "lane-merged", spec, { files: m.applied.length, removed: m.deleted.length, events: m.events });
          log(`kcc: ${spec} merged (${m.applied.length} files, ${m.events} events)`);
          rmSync(dir, { recursive: true, force: true });
        }
      }
      save();
      running.delete(spec);
    })());
  };

  const tick = async (): Promise<void> => {
    await Bun.sleep((o.syncSeconds ?? 20) * 1000);
    for (const spec of running.keys()) {
      const lane = state[spec];
      if (!lane) continue;
      syncOwned(root, lane.dir, ownedPaths(root, spec));
      syncBackchannel(root, lane.dir);
    }
    if (!o.runDriver) runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
  };

  for (;;) {
    const blocked = new Set(Object.entries(state).filter(([, l]) => l.status === "failed").map(([s]) => s));
    for (const spec of readySpecs(rows, state)) {
      if (running.size >= o.maxParallel || blocked.has(spec)) break;
      start(spec);
    }
    if (!running.size) break;
    await Promise.race([...running.values(), tick()]);
  }
  if (!o.runDriver) runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
  const stopped = rows.filter((r) => state[r.spec]?.status !== "merged").map((r) => r.spec);
  if (!stopped.length) return 0;
  for (const s of stopped) {
    const lane = state[s];
    log(lane ? `kcc: ${s} needs attention: ${lane.reason ?? lane.status}. Answer with: kcc run --lane ${s} --answer <choice>, then kcc run --resume` : `kcc: ${s} waits for its dependencies`);
  }
  return 4;
}
