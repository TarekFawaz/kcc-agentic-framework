import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { UsageError, workspace } from "../args";
import { readJson, writeJson } from "../fsutil";
import { isWindows, runTool, runToolAsync } from "../platform";
import { readSettings } from "../settings";
import { startDashboardServer, type DashServer } from "../commands/dashboard";
import { findRoadmap, laneDir, liveSyncLane, fanoutSpecs, scheduleSpecs } from "./lanes";
import { routeAll } from "./routing";
import { detectLimit, latestTranscriptLimit, loadPatterns, sessionId } from "./limits";

const RESUME_PROMPT = "Read coordination/checkpoints/latest.md and continue the KCC run from next_action.";
const BYPASS = /dangerously|bypassPermissions|--yolo|skip-permissions/i;

export interface LimitRecord {
  harness: string;
  source: string;
  at: number;
  resets_at: number | null;
  resume_at: number | null;
  resumes: number;
  status: "waiting" | "resumed" | "gave-up";
}

export function limitFile(root: string): string {
  return join(root, "coordination", "run", "limit.json");
}

function quote(arg: string): string {
  if (/^[A-Za-z0-9_\-.:\\/=@%+,]+$/.test(arg)) return arg;
  return isWindows ? `"${arg.replace(/"/g, '\\"')}"` : `'${arg.replace(/'/g, `'\\''`)}'`;
}

function clock(epoch: number): string {
  return new Date(epoch * 1000).toLocaleString();
}

/** Runs a command line through the OS shell, echoing output and keeping the tail. */
function runStreaming(commandLine: string, cwd: string): Promise<{ status: number; lines: string[] }> {
  return new Promise((done) => {
    const lines: string[] = [];
    const child = spawn(commandLine, { cwd, shell: true, stdio: ["inherit", "pipe", "pipe"] });
    const collect = (chunk: Buffer, out: NodeJS.WriteStream): void => {
      out.write(chunk);
      for (const l of chunk.toString("utf8").split(/\r?\n/)) if (l) lines.push(l);
      if (lines.length > 400) lines.splice(0, lines.length - 400);
    };
    child.stdout?.on("data", (c: Buffer) => collect(c, process.stdout));
    child.stderr?.on("data", (c: Buffer) => collect(c, process.stderr));
    child.on("error", (e) => {
      lines.push(String(e.message));
      done({ status: 127, lines });
    });
    child.on("close", (code) => done({ status: code ?? 1, lines }));
  });
}

async function waitUntil(epoch: number): Promise<void> {
  for (;;) {
    const left = epoch - Math.floor(Date.now() / 1000);
    if (left <= 0) return;
    await Bun.sleep(Math.min(left, 60) * 1000);
  }
}

interface Policy {
  harness: string;
  grace: number;
  defaultWait: number;
  maxResumes: number;
}

function policy(root: string, harness: string | undefined, maxResumes: string | undefined): Policy {
  const s = readSettings(root);
  const c = s?.continuity ?? {};
  return {
    harness: harness ?? s?.run?.harness ?? "claude",
    grace: c.resume_grace_seconds ?? 120,
    defaultWait: (c.default_wait_minutes ?? 300) * 60,
    maxResumes: maxResumes !== undefined ? Number(maxResumes) : (c.max_resumes ?? 5),
  };
}

/** Records the limit, waits for the reset, and reports whether another attempt is allowed. */
async function holdForReset(root: string, p: Policy, source: string, resetsAt: number | undefined, resumes: number): Promise<boolean> {
  const now = Math.floor(Date.now() / 1000);
  const rec: LimitRecord = { harness: p.harness, source, at: now, resets_at: resetsAt ?? null, resume_at: null, resumes, status: "gave-up" };
  if (resumes >= p.maxResumes) {
    writeJson(limitFile(root), rec);
    console.error(`kcc: usage limit reached again and max_resumes (${p.maxResumes}) is used up. Continue later with: kcc run --resume`);
    return false;
  }
  const resumeAt = (resetsAt ?? now + p.defaultWait) + p.grace;
  writeJson(limitFile(root), { ...rec, resume_at: resumeAt, status: "waiting" });
  const why = resetsAt ? `reset at ${clock(resetsAt)}` : `no reset time in the output, using default_wait_minutes`;
  console.error(`kcc: usage limit reached on ${p.harness} (${why}). Resuming at ${clock(resumeAt)} (attempt ${resumes + 1} of ${p.maxResumes}). Ctrl+C stops the wait; continue later with: kcc run --resume`);
  await waitUntil(resumeAt);
  writeJson(limitFile(root), { ...rec, resume_at: resumeAt, resumes: resumes + 1, status: "resumed" });
  return true;
}

/** Supervises the vendored `kcc-run` driver: on exit 5 (usage limit) it waits and resumes. */
async function superviseDriver(root: string, args: string[], p: Policy, wait: boolean): Promise<number> {
  let current = args;
  for (let resumes = 0; ; resumes++) {
    const r = runTool(root, "kcc-run", current, { env: wait ? { KCC_SUPERVISED: "1" } : {} });
    if (r.stderr) console.error(r.stderr);
    if (r.status !== 5 || !wait) return r.status;
    const rec = readJson<{ resets_at?: number | null }>(limitFile(root));
    if (!(await holdForReset(root, p, "kcc-run", rec?.resets_at ?? undefined, resumes))) return 5;
    current = ["--resume", "--repo-root", root];
  }
}

/**
 * Runs one lane's driver on its own (`kcc run --lane SPEC-X ...`). Unlike the scheduler it used to copy nothing back, so the
 * workspace and the dashboard kept showing the gate as open and the old bugs for the whole run. This keeps the same live sync
 * the scheduler does while the driver runs, and prints a line so the console shows it is working.
 */
async function superviseLane(root: string, dir: string, spec: string, args: string[], p: Policy, wait: boolean): Promise<number> {
  const sync = (): void => {
    try {
      liveSyncLane(root, dir, spec);
      runTool(root, "build-dashboard", ["--repo-root", root], { capture: true });
    } catch {
      /* a convenience copy; never stops the lane */
    }
  };
  console.log(`kcc: running  in its lane; the workspace and the dashboard are synced every 20 seconds`);
  const timer = setInterval(sync, 20000);
  try {
    let current = args;
    for (let resumes = 0; ; resumes++) {
      const r = await runToolAsync(dir, "kcc-run", current, { capture: false, env: wait ? { KCC_SUPERVISED: "1" } : {} });
      if (r.status !== 5 || !wait) return r.status;
      const rec = readJson<{ resets_at?: number | null }>(limitFile(dir));
      if (!(await holdForReset(dir, p, "kcc-run", rec?.resets_at ?? undefined, resumes))) return 5;
      current = ["--resume", "--repo-root", dir];
    }
  } finally {
    clearInterval(timer);
    sync();
  }
}

function resumeCommand(root: string, p: Policy, original: string[], lines: string[]): string {
  const c = readSettings(root)?.continuity ?? {};
  const sid = sessionId(lines);
  let tpl = c.resume?.[p.harness] ?? null;
  if (!tpl || (tpl.includes("{session_id}") && !sid)) tpl = c.start?.[p.harness] ?? null;
  if (!tpl) tpl = '{command} "{resume_prompt}"';
  if (BYPASS.test(tpl)) throw new UsageError(`the resume template for '${p.harness}' uses a permission-bypass flag; KCC will not run it. Edit continuity in .KCC/settings.json.`);
  return tpl
    .replaceAll("{session_id}", sid ?? "")
    .replaceAll("{permission_mode}", c.permission_mode ?? "auto")
    .replaceAll("{resume_prompt}", RESUME_PROMPT)
    .replaceAll("{command}", quote(original[0] ?? p.harness));
}

/** Supervises any harness command: detects a limit in its output, waits, resumes. */
async function superviseWrapped(root: string, command: string[], p: Policy, wait: boolean): Promise<number> {
  const patterns = loadPatterns(root, p.harness);
  if (wait) resumeCommand(root, p, command, []); // refuse a bypass template before any work or waiting
  let line = command.map(quote).join(" ");
  for (let resumes = 0; ; resumes++) {
    const r = await runStreaming(line, root);
    const hit = detectLimit(r.lines, r.status, patterns);
    if (!hit.hit) return r.status;
    const cp = runTool(root, "kcc-checkpoint", ["--reason", "limit-hard", "--harness", p.harness, "--next-action", "Resume the interrupted harness session", "--repo-root", root], { capture: true });
    if (cp.status !== 0) console.error(`kcc: warning: kcc-checkpoint exited ${cp.status}`);
    if (!wait) {
      writeJson(limitFile(root), { harness: p.harness, source: hit.source, at: Math.floor(Date.now() / 1000), resets_at: hit.resetsAt ?? null, resume_at: null, resumes, status: "gave-up" } satisfies LimitRecord);
      return 5;
    }
    if (!(await holdForReset(root, p, hit.source, hit.resetsAt, resumes))) return 5;
    line = resumeCommand(root, p, command, r.lines);
  }
}

/**
 * The live dashboard of a run: served for as long as `kcc run` lives, rebuilt from the files on each request. The page
 * therefore cannot go stale the way a generated file does when the process that regenerates it stops.
 */
function serveRunDashboard(argv: string[]): DashServer | undefined {
  if (["--dry-run", "--help", "-h", "--wrap"].some((f) => argv.includes(f)) || process.env.KCC_NO_DASH_SERVER === "1") return undefined;
  const i = argv.indexOf("--dir");
  let root: string;
  try {
    root = workspace(i >= 0 ? argv[i + 1] : undefined);
  } catch {
    return undefined;
  }
  const dash = (readSettings(root) as { dashboard?: { serve?: unknown } } | undefined)?.dashboard;
  if (dash?.serve === false) return undefined;
  const server = startDashboardServer(root);
  if (server) {
    process.env.KCC_DASHBOARD_URL = server.url;
    console.log(`kcc: live dashboard ${server.url} (rebuilt from the workspace files on every request; it ends with this command)`);
  }
  return server;
}

export async function run(argv: string[]): Promise<number> {
  const server = serveRunDashboard(argv);
  try {
    return await runInner(argv);
  } finally {
    server?.stop();
  }
}

async function runInner(argv: string[]): Promise<number> {
  // Own flags are taken out by hand: everything else belongs to kcc-run or the wrapped command.
  const sep = argv.indexOf("--");
  const own = sep >= 0 ? argv.slice(0, sep) : argv;
  const wrapped = sep >= 0 ? argv.slice(sep + 1) : [];
  const rest: string[] = [];
  let dir: string | undefined;
  let harness: string | undefined;
  let maxResumes: string | undefined;
  let wrap = false;
  let wait = true;
  let lane: string | undefined;
  let maxParallel = 4;
  for (let i = 0; i < own.length; i++) {
    const a = own[i] ?? "";
    if (a === "--wrap") wrap = true;
    else if (a === "--no-wait") wait = false;
    else if (a === "--dir") dir = own[++i];
    else if (a === "--max-resumes") maxResumes = own[++i];
    else if (a === "--lane") lane = (own[++i] ?? "").toUpperCase();
    else if (a === "--max-parallel") maxParallel = Number(own[++i]);
    else if (a === "--harness") {
      harness = own[++i];
      if (harness) rest.push("--harness", harness);
    } else rest.push(a);
  }
  const root = workspace(dir);
  const p = policy(root, harness, maxResumes);
  if (!Number.isInteger(p.maxResumes) || p.maxResumes < 0) throw new UsageError("--max-resumes expects a whole number");
  if (!Number.isInteger(maxParallel) || maxParallel < 1) throw new UsageError("--max-parallel expects a whole number >= 1");

  if (wrap) {
    if (!wrapped.length) throw new UsageError("usage: kcc run --wrap [--harness <name>] -- <harness command...>");
    return superviseWrapped(root, wrapped, p, wait);
  }
  // `--lane SPEC-X` targets one spec's lane, e.g. to answer the gate it stopped at.
  if (lane) {
    const dir = laneDir(root, lane);
    if (!existsSync(join(dir, "coordination", "run", "run.json"))) throw new UsageError(`no lane for ${lane} (expected ${dir})`);
    return superviseLane(root, dir, lane, [...rest, "--repo-root", dir], p, wait);
  }
  // A dry run or a status query never waits.
  const passive = rest.includes("--dry-run") || rest.includes("--help") || rest.includes("-h");
  const manual = ["--only", "--from", "--until", "--answer", "--dry-run", "--help", "-h"].some((f) => rest.includes(f));
  const input = rest[rest.indexOf("--input") + 1] ?? "";
  const lifecycle = !manual && ((rest.includes("--input") && !/^SPEC-\d+$/i.test(input)) || rest.includes("--resume"));
  if (!lifecycle) {
    if (!rest.includes("--repo-root")) rest.push("--repo-root", root);
    return superviseDriver(root, rest, p, wait && !passive);
  }
  return lifecycleRun(root, rest, p, wait, maxParallel);
}

/** kcc-run flags that every lane and the closing run inherit. */
function laneFlags(args: string[]): string[] {
  const out: string[] = [];
  const valued = new Set(["--depthlevel", "--accuracy", "--budget", "--currency", "--harness", "--max-attempts"]);
  for (let i = 0; i < args.length; i++) {
    const a = args[i] ?? "";
    if (valued.has(a)) out.push(a, args[++i] ?? "");
    else if (["--silent", "--assume", "--fasttrack", "--parallel"].includes(a)) out.push(a);
  }
  return out;
}

/**
 * The whole lifecycle: the shared states once (REPO .. SPECS), then the WRITE and PLAN states, each for every
 * spec at the same time (a spec-writer, then a planner, per spec, up to --max-parallel, in lanes), then every spec as soon as the specs it depends on are done
 * (independent specs at the same time, in their own lanes), then CLOSE once. The bare kcc-run driver has no scheduler:
 * it plans spec by spec, in the table's own order.
 */
async function lifecycleRun(root: string, args: string[], p: Policy, wait: boolean, maxParallel: number): Promise<number> {
  const flags = laneFlags(args);
  const runJson = readJson<{ state?: string; status?: string; fasttrack?: string; depthlevel?: string; silent?: string }>(join(root, "coordination", "run", "run.json"));
  // A resumed run keeps the policy it started with: its lanes must use the same state table.
  if (runJson?.fasttrack === "1" && !flags.includes("--fasttrack")) flags.push("--fasttrack");
  if (runJson?.silent === "1" && !flags.includes("--silent")) flags.push("--silent", "--assume");
  if (runJson?.depthlevel && !flags.includes("--depthlevel")) flags.push("--depthlevel", runJson.depthlevel);
  if (runJson?.status === "done") {
    console.log("kcc: the run is DONE; nothing to resume");
    return 0;
  }
  const lanesStarted = existsSync(join(root, "coordination", "lanes.json"));
  if (!lanesStarted && Number(runJson?.state ?? 0) <= 9) {
    const a = await superviseDriver(root, [...args.filter((x) => x !== "--repo-root"), "--until", "9", "--repo-root", root], p, wait);
    if (a !== 0) return a;
  }
  if (!findRoadmap(root)) {
    console.error("kcc: the shared states finished but no specs/IDEA-*/ROADMAP.md exists");
    return 6;
  }
  // Writing or planning one spec needs only its own files, the architecture and the dialects, so all specs go at the same time.
  const fanned = await fanoutSpecs(root, { passthrough: flags, maxParallel });
  if (fanned.code !== 0) return fanned.code;
  try {
    const routed = routeAll(root);
    if (routed.length) console.log(`kcc: routed ${routed.reduce((n, r) => n + r.routes.length, 0)} backlog items in ${routed.length} plans (model and effort per item, in plan.md -> ## Routing)`);
  } catch {
    /* routing is guidance for the drivers; a plan it cannot read keeps the driver's own rules */
  }
  const b = await scheduleSpecs(root, { passthrough: flags, maxParallel, from: fanned.after });
  if (b !== 0) return b;
  return superviseDriver(root, ["--resume", "--from", "18", ...flags, "--repo-root", root], p, wait);
}

export function limits(argv: string[]): number {
  const json = argv.includes("--json");
  const i = argv.indexOf("--dir");
  const root = workspace(i >= 0 ? argv[i + 1] : undefined);
  const usage = readJson<Record<string, unknown>>(join(root, "coordination", "usage.json"));
  const last = readJson<LimitRecord>(limitFile(root));
  const runState = readJson<{ status?: string; reason?: string }>(join(root, "coordination", "run", "run.json"));
  if (json) {
    console.log(JSON.stringify({ usage: usage ?? null, last_limit: last ?? null, run: runState ?? null }, null, 2));
    return 0;
  }
  const win = (name: string): string => {
    const w = usage?.[name] as { pct?: number; resets_at?: number | null } | undefined;
    if (!w || w.pct === undefined || w.pct === null) return "unknown";
    return `${w.pct}%${w.resets_at ? `, resets ${clock(w.resets_at)}` : ""}`;
  };
  console.log("Usage (Claude Code status line; other harnesses do not report usage):");
  if (usage) console.log(`  5-hour window: ${win("five_hour")}\n  7-day window:  ${win("seven_day")}`);
  else {
    console.log("  no percentages: coordination/usage.json is written only by the Claude Code status line,");
    console.log("  which the VS Code extension and `claude -p` do not run. A limit that is hit is still caught");
    console.log("  by the StopFailure hook (kcc-limit-hook), which reads the reset time from the session transcript.");
  }
  const seen = latestTranscriptLimit(root);
  if (seen) {
    const live = seen.resetsAt !== undefined && seen.resetsAt * 1000 > Date.now();
    const reset = seen.resetsAt ? `reset ${clock(seen.resetsAt)}${live ? " (still blocked)" : " (already reset)"}` : "reset not stated";
    console.log(`Claude session transcripts: last limit message ${seen.at ? clock(seen.at) : "(time unknown)"}${seen.window ? `, ${seen.window} window` : ""}, ${reset}`);
  }
  console.log("Last limit:");
  if (!last) console.log("  none recorded");
  else {
    console.log(`  harness ${last.harness}, detected by ${last.source} at ${clock(last.at)}`);
    console.log(`  reset: ${last.resets_at ? clock(last.resets_at) : "not stated"} | status: ${last.status}${last.resume_at && last.status === "waiting" ? `, resuming ${clock(last.resume_at)}` : ""} | resumes used: ${last.resumes}`);
  }
  console.log(`Run: ${runState?.status ?? "no run recorded"}${runState?.reason ? ` (${runState.reason})` : ""}`);
  return 0;
}
